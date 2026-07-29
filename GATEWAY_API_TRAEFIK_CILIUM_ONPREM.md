# Traefik + Gateway API sur cluster Kubernetes on-premise (CNI Cilium, L2 Announcements)

> Variante on-premise/bare-metal du guide `GATEWAY_API_TRAEFIK.md`. Différence
> fondamentale : sans cloud provider (AWS/Azure/GCP), rien n'attribue
> automatiquement une IP externe à un `Service type=LoadBalancer` ni ne la
> rend joignable sur le réseau local. C'est le rôle de **Cilium L2
> Announcements** + **CiliumLoadBalancerIPPool** — l'équivalent, côté Cilium,
> de ce que fait MetalLB en mode L2 sur d'autres CNI.

## Principe

| Brique | Rôle |
|---|---|
| `CiliumLoadBalancerIPPool` | Définit la plage d'IP du réseau local pouvant être attribuée aux `Service type=LoadBalancer` |
| `CiliumL2AnnouncementPolicy` | Désigne quels nœuds/interfaces annoncent ces IP sur le réseau local (ARP gratuit / NDP) |
| Traefik (`Service type=LoadBalancer`) | Reçoit une IP de ce pool, annoncée en L2 — joignable directement par les clients du LAN |
| `Gateway`/`HTTPRoute` | Identique au guide AWS — le routage L7 ne change pas |

Contrairement à AWS/NLB, **un seul nœud à la fois** répond aux requêtes ARP
pour une IP donnée (élection de leader via `Lease` Kubernetes) : c'est de la
haute disponibilité par bascule (failover), pas un vrai équilibrage de
charge L2. Le vrai équilibrage se fait ensuite en interne par le datapath
eBPF de Cilium (kube-proxy replacement), qui redistribue vers n'importe quel
pod du cluster une fois le paquet reçu par le nœud "leader".

## Prérequis

- Cilium installé comme **CNI principal** du cluster (pas en complément d'un
  autre CNI)
- Nœuds sur le **même segment L2** (même VLAN/broadcast domain) que les
  clients qui doivent joindre le LoadBalancer — les annonces ARP ne
  traversent pas les routeurs. Pour un déploiement multi-site/routé, utiliser
  le **BGP Control Plane** de Cilium à la place (hors périmètre de ce guide).
- Une **plage d'IP libre** sur ce réseau local, en dehors du range DHCP, à
  réserver pour les `Service type=LoadBalancer`

## Étape 1 — Activer L2 Announcements dans Cilium

Si Cilium est déjà installé, mettre à jour les values Helm :

```yaml
kubeProxyReplacement: true   # requis pour un fonctionnement correct des IP LB

l2announcements:
  enabled: true

externalIPs:
  enabled: true

k8sClientRateLimit:
  qps: 10
  burst: 20
```

```bash
helm upgrade cilium cilium/cilium -n kube-system -f cilium-values.yaml
kubectl -n kube-system rollout status daemonset/cilium
```

Vérifier que le kube-proxy replacement est actif :

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement
# → doit afficher "True" / "Strict"
```

## Étape 2 — Déclarer le pool d'IP (`CiliumLoadBalancerIPPool`)

```yaml
apiVersion: "cilium.io/v2alpha1"
kind: CiliumLoadBalancerIPPool
metadata:
  name: pool-lan
spec:
  blocks:
    - cidr: "192.168.1.240/28"   # adapter à votre réseau — hors plage DHCP
```

```bash
kubectl apply -f ip-pool.yaml
kubectl get ciliumloadbalancerippool
```

## Étape 3 — Déclarer la politique d'annonce L2 (`CiliumL2AnnouncementPolicy`)

```yaml
apiVersion: "cilium.io/v2alpha1"
kind: CiliumL2AnnouncementPolicy
metadata:
  name: l2-policy-default
spec:
  externalIPs: true
  loadBalancerIPs: true
  interfaces:
    - ^eth[0-9]+       # adapter au nom réel de l'interface réseau des nœuds
  nodeSelector:
    matchLabels:
      kubernetes.io/os: linux   # tous les nœuds Linux éligibles ; restreindre si besoin
```

```bash
kubectl apply -f l2-policy.yaml
kubectl get ciliuml2announcementpolicy
```

## Étape 4 — Installer Traefik (sans annotations cloud)

Différence clé avec la version AWS : **pas d'annotation de LB cloud**, et
optionnellement fixer l'IP désirée depuis le pool :

```yaml
deployment:
  replicas: 3

service:
  spec:
    type: LoadBalancer
  # Optionnel : forcer une IP précise du pool plutôt qu'une attribution automatique
  # annotations:
  #   "io.cilium/lb-ipam-ips": "192.168.1.241"

providers:
  kubernetesIngress:
    enabled: true
  kubernetesGateway:
    enabled: true
    experimentalChannel: false

gateway:
  enabled: true
  listeners:
    web:
      namespacePolicy:
        from: All

gatewayClass:
  enabled: true
```

```bash
helm install traefik traefik/traefik -n traefik --create-namespace -f traefik-values.yaml
```

## Étape 5 — Vérifier

```bash
# L'IP externe doit venir du pool déclaré à l'étape 2
kubectl get svc -n traefik traefik -o wide

# Quel nœud annonce actuellement cette IP (élection de leader)
kubectl get lease -n kube-system | grep cilium-l2announce

# Depuis une autre machine du même réseau local :
arping 192.168.1.241
ip neigh show 192.168.1.241   # doit résoudre vers la MAC du nœud leader
curl http://192.168.1.241/
```

Le reste (exposer une app via `HTTPRoute`, tester par hostname) est
**identique** au guide AWS — voir `GATEWAY_API_TRAEFIK.md`, étapes 4-5.

## Pièges spécifiques à Cilium L2 Announcements

### Pas de vrai équilibrage L2
Une seule IP = un seul nœud "leader" répond aux ARP à un instant T. En cas de
panne de ce nœud, un autre reprend le lease (quelques secondes de coupure),
mais il n'y a **pas de répartition de charge entre plusieurs nœuds** au
niveau L2 — uniquement de la HA par bascule. La répartition réelle du trafic
entre pods se fait ensuite via l'eBPF datapath de Cilium.

### Adjacence L2 obligatoire
Les annonces ARP/NDP ne franchissent pas un routeur. Si vos clients sont sur
un autre VLAN/sous-réseau que les nœuds du cluster, cette approche ne
fonctionnera pas — utiliser le **BGP Control Plane** de Cilium à la place
(annonce des routes vers un routeur/switch qui supporte BGP).

### Kube-proxy replacement requis
Sans `kubeProxyReplacement: true` (ou au minimum en mode partiel avec
`externalIPs.enabled`), le routage vers les IP du pool peut ne pas
fonctionner correctement. Vérifier `cilium-dbg status` après toute
installation.

### Conflit avec le range DHCP
Le pool d'IP doit être **explicitement exclu** du range DHCP de votre routeur
réseau, sinon un appareil peut se voir attribuer une IP déjà utilisée par un
`Service` Kubernetes (collision d'adresse).

### Switches avec port security / DHCP snooping strict
Certains switches d'entreprise bloquent le trafic ARP gratuit ("gratuitous
ARP") par défaut (protection anti-spoofing). Si l'IP n'est jamais joignable
malgré une policy `Accepted`, vérifier la configuration du switch avant de
suspecter Cilium.

### Interface mal détectée
Le champ `interfaces` de `CiliumL2AnnouncementPolicy` est une **regex** sur
le nom de l'interface réseau — une valeur incorrecte (ex. `eth0` en dur sur
un nœud où l'interface s'appelle `ens33`) fait échouer silencieusement
l'annonce sur ce nœud. Vérifier avec `ip link` sur chaque nœud si un pool ne
devient jamais joignable.
