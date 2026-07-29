# Installation et configuration de Traefik + Gateway API sur un cluster EKS existant

> Guide pratique pour exposer des applications vers l'extérieur via un unique
> Load Balancer, en utilisant Traefik comme implémentation de la Gateway API
> Kubernetes. Rédigé à partir d'une installation réelle (retours d'expérience
> et pièges rencontrés inclus). S'applique à un cluster **déjà provisionné**
> (peu importe comment : `eksctl`, Terraform, console AWS).

## Pourquoi Gateway API plutôt qu'un Ingress classique ou un Service par app

Sans contrôleur d'entrée partagé, chaque `Service type=LoadBalancer` crée un
Load Balancer AWS dédié (Classic ELB ou NLB) — facturé à l'heure, en continu,
par application. Avec Traefik + Gateway API :

- **1 seul Load Balancer** pour toutes les applications
- Routage par nom d'hôte (`HTTPRoute`) vers le bon `Service` en interne
- Base commune pour ajouter TLS, rate limiting, middlewares, etc. plus tard

## Prérequis

- `kubectl` configuré et pointé sur le cluster (`aws eks update-kubeconfig ...`)
- `helm` (v3) installé
- Les **subnets publics** du VPC doivent porter le tag
  `kubernetes.io/role/elb = 1` (sinon le NLB ne pourra pas être provisionné
  automatiquement — c'est un tag standard du cloud provider AWS pour
  Kubernetes, pas spécifique à Traefik)

## Vue d'ensemble : les 3 objets Gateway API

| Objet | Portée | Rôle |
|---|---|---|
| `GatewayClass` | Cluster | Déclare quel contrôleur implémente la Gateway (ici `traefik.io/gateway-controller`) |
| `Gateway` | Namespace (celui de Traefik) | Le point d'entrée réseau partagé : listener(s), port(s), et **qui a le droit d'y attacher des routes** |
| `HTTPRoute` | Namespace de l'application | La règle de routage elle-même : quel(s) hostname(s) → quel `Service` backend |

## Étape 1 — Installer les CRDs Gateway API

Les CRDs (`Gateway`, `HTTPRoute`, `GatewayClass`, etc.) ne sont **pas incluses**
par défaut dans un cluster EKS, ni installées automatiquement par le chart
Traefik. Il faut les poser explicitement, **avant** d'installer Traefik :

```bash
kubectl apply --server-side \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
```

⚠️ `--server-side` est nécessaire : ces CRDs sont volumineuses et dépassent la
limite de taille des annotations utilisées par l'apply classique
(`kubectl apply` sans `--server-side` échoue souvent dessus).

Vérifier :

```bash
kubectl get crd | grep gateway.networking.k8s.io
```

## Étape 2 — Installer Traefik via Helm

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
```

Fichier de values (`traefik-values.yaml`) — les points importants sont commentés :

```yaml
deployment:
  replicas: 3   # répartis sur plusieurs nœuds/AZ pour la HA

topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: traefik

service:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
  spec:
    type: LoadBalancer   # ⚠️ sous service.spec, pas service.type directement

providers:
  kubernetesIngress:
    enabled: true        # garde la compatibilité avec les Ingress classiques
  kubernetesGateway:
    enabled: true         # active le provider Gateway API
    experimentalChannel: false   # false = CRDs "standard channel" (v1.6.1 ci-dessus)

gateway:
  enabled: true            # Traefik crée une Gateway par défaut
  listeners:
    web:
      namespacePolicy:
        from: All          # ⚠️ IMPORTANT — voir "Piège n°1" ci-dessous

gatewayClass:
  enabled: true             # Traefik crée aussi la GatewayClass par défaut
```

```bash
helm install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  -f traefik-values.yaml
```

## Étape 3 — Vérifier l'installation

```bash
kubectl get gatewayclass
kubectl get gateway -n traefik
kubectl describe gateway traefik-gateway -n traefik
kubectl get svc -n traefik traefik
```

Attendu :
- `GatewayClass` → `ACCEPTED: True`
- `Gateway` → `PROGRAMMED: True`, une `ADDRESS` (hostname du LB) renseignée
- Le `Service` traefik a un `EXTERNAL-IP` (hostname NLB, peut prendre 1-2 min à apparaître)

## Étape 4 — Exposer une application

1. Le `Service` de l'application doit être en `ClusterIP` (pas
   `LoadBalancer` — sinon elle crée son propre LB en plus de celui de Traefik).

2. Créer une `HTTPRoute` :

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mon-app
  namespace: mon-namespace
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
  hostnames:
    - "mon-app.mondomaine.com"
  rules:
    - backendRefs:
        - name: mon-service
          port: 80
```

```bash
kubectl apply -f httproute.yaml
kubectl get httproute -n mon-namespace mon-app -o jsonpath='{.status.parents[0].conditions}'
```

Attendu : conditions `Accepted: True` et `ResolvedRefs: True`. Si absent/faux,
voir "Piège n°1" ci-dessous.

## Étape 5 — Tester

```bash
# Récupérer le hostname du LB
kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Tester sans toucher au DNS (simule un vrai hostname)
curl --resolve mon-app.mondomaine.com:80:<IP_DU_LB> http://mon-app.mondomaine.com/
```

Pour un test local durable, ajouter au fichier hosts (`/etc/hosts` ou
`C:\Windows\System32\drivers\etc\hosts` en admin) :
```
<IP_DU_LB>  mon-app.mondomaine.com
```
⚠️ Un NLB AWS a une IP par AZ, pas une IP fixe unique — elle peut changer si
AWS reprovisionne les nœuds du LB. Ne pas s'y fier pour un usage durable
au-delà d'un test.

## Pièges réellement rencontrés

### Piège n°1 — `namespacePolicy` par défaut = `Same`

Par défaut, le chart Traefik crée une Gateway dont le listener n'accepte les
`HTTPRoute` **que du même namespace** (`traefik`). Si votre application est
dans un autre namespace (ce qui est presque toujours le cas), sa `HTTPRoute`
sera silencieusement ignorée — `kubectl get httproute` ne montre aucune
erreur bloquante, mais `status.parents` reste vide ou `Accepted: False`.
**Solution** : `gateway.listeners.web.namespacePolicy.from: All` dans les
values (déjà inclus ci-dessus).

### Piège n°2 — Pas de HTTPS par défaut

Le listener `websecure` (443/TLS) du chart Traefik est **désactivé par
défaut** car il exige un certificat (`certificateRefs`). Sans certificat
configuré, forcer une redirection HTTP→HTTPS revient à rediriger vers une
impasse (aucun listener ne répond en HTTPS). Pour une vraie prod, prévoir
soit `cert-manager` + Let's Encrypt (DNS-01 ou HTTP-01), soit un certificat
ACM si vous basculez vers un ALB, **avant** d'activer la redirection.

### Piège n°3 — Repo Helm non enregistré localement

`terraform`/CI peuvent installer un chart Helm sans jamais faire
`helm repo add` sur le poste — `helm list` et `helm show values` échouent
alors localement ("repo introuvable") même si la release tourne bien sur le
cluster. Faire `helm repo add traefik https://traefik.github.io/charts` avant
toute inspection manuelle.

### Piège n°4 — Nom de service Gateway API strict

`HTTPRoute.spec.backendRefs[].name` doit être le nom exact du `Service`
Kubernetes (pas du déploiement Helm ni de l'app). Vérifier avec
`kubectl get svc -n <namespace>`.

## Alternative : gérer Traefik via Terraform (si le cluster est en IaC)

Si le cluster est provisionné par Terraform, Traefik peut être géré comme
ressource `helm_release` plutôt qu'installé à la main :

```hcl
provider "kubernetes" {
  host                   = aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

resource "null_resource" "gateway_api_crds" {
  provisioner "local-exec" {
    command = "kubectl apply --server-side --context ${aws_eks_cluster.this.arn} -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml"
  }
}

resource "helm_release" "traefik" {
  name       = "traefik"
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  namespace  = "traefik"
  create_namespace = true
  values     = [yamlencode({ /* mêmes clés que ci-dessus */ })]
  depends_on = [null_resource.gateway_api_crds]
}
```

⚠️ **Piège spécifique à cette approche** : si vous modifiez en même temps un
attribut du cluster EKS lui-même (ex. `deletion_protection`) dans le même
`terraform plan`, Terraform peut échouer avec `Kubernetes cluster
unreachable: the server has asked for the client to provide credentials`.
Cause : le token du provider Kubernetes/Helm dépend d'un attribut du cluster
qui a un changement "en attente", donc son évaluation est différée et le
provider ne peut pas s'authentifier pendant le plan. **Solution** : appliquer
le changement sur le cluster séparément (`terraform apply
-target=aws_eks_cluster.this`) avant de re-planifier le reste.
