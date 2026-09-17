Scop
Infrastructură pentru aplicația demo-app — acoperă producție, dezvoltare și monitorizare, cu automatizare completă de la zero (o singură comandă) până la un cluster funcțional.

Descriere
Aplicația rulează într-un cluster Kubernetes (k3s), format din 3 noduri simetrice — fiecare este simultan control-plane și worker (etcd distribuit, fără noduri dedicate exclusiv unui singur rol). Serviciile de suport (NFS, Vault, GitLab, monitorizare) rulează separat, pe o singură mașină dedicată.

Virtualizarea folosește libvirt/KVM — virtualizare nativă Linux, aleasă din motive de resurse disponibile și de automatizare (control complet prin Terraform, foloseste cloud-init).

Resurse necesare: 10 vCPU / 24GB RAM total (mașina de suport: 4 vCPU / 12GB; cele 3 noduri k3s: 2 vCPU / 4GB fiecare).

Instalare: complet automată, printr-un singur script (install.sh) — descarcă imaginea cloud Ubuntu (verificată prin hash, versiune fixată), generează perechea de chei SSH dedicată proiectului, apoi rulează în ordine Terraform și Ansible pentru ambele componente (mașina de suport, apoi clusterul).

Customizare: prin fișiere de configurare, fără a atinge logica din cod — variables.tf (resurse, rețea, dimensiuni discuri) și group_vars/all.yml (comportament Ansible, subnet-uri cluster, politici de repornire).

Politica update/restart: playbook-ul de actualizare a sistemului de operare rulează apt update + dist-upgrade pe toate mașinile, idempotent (fără pachete noi, nu raportează nicio schimbare). Repornirea sistemului NU se face niciodată implicit - se declanșează doar dacă sunt îndeplinite simultan două condiții: (1) kernelul/pachetele actualizate chiar o cer (verificat prin /var/run/reboot-required) și (2) host-ul respectiv are explicit allow_reboot: true. Fără a doua condiție, playbook-ul doar avertizează ce host are nevoie de repornire și de ce, fără s-o execute automat.

Suport (mașina dedicată)
Vault — sursă unică de secrete și PKI pentru tot proiectul:

Infrastructură de certificate: rădăcină CA proprie + CA intermediară, folosită pentru TLS-ul tuturor serviciilor interne
Secrete: autentificare bazată pe Kubernetes (JWT + TokenReview), nu pe token-uri statice — folosită de cert-manager și External Secrets Operator
secretele, parole/tokenuri initiale sunt generate aleator si incarcate in vault

GitLab — preconfigurat cu două proiecte si cicd:

demo-app (codul sursă) și manifests-demo-app (manifestele Kubernetes)
CI/CD: build imagine (Kaniko) + actualizare automată a tag-ului în manifeste, pe bază de Kustomize
Runner cu executor Kubernetes, dedicat build-ului și actualizării tag-ului
Restricție pe manifests-demo-app: merge-ul în producție necesită Merge Request aprobat manual (nu se face push direct)
Gitlab are si functia de registru intern pentru imaginile generate pentru demo-app.

SigNoz — soluție unificată de observabilitate (log-uri, metrici, trace-uri):
Punct central de colectare, alimentat prin OTLP de la colectoarele locale din cluster (care funcționează ca intermediari, nu ca sursă finală)
Vine preconfigurat cu o alertă care monitorizează disponibilitatea Kafka, Keycloak și Redis

NFS — montat în demo-app la /app/shared-data, via PVC demo-app-shared-data (storageClassName: nfs, ReadWriteMany). Rol demonstrativ — infrastructura e funcțională și accesibilă simultan de ambele replici, dar aplicația nu scrie încă date pe el.

Clusterul Kubernetes
cert-manager — emite certificate din Vault (PKI intermediară) pentru toate aplicațiile din cluster care au nevoie de TLS.

ArgoCD — preconfigurat cu două aplicații: demo-app (producție) și dev-demo-app (dezvoltare), fiecare sincronizată din branch-ul/overlay-ul corespunzător.

SSO (Keycloak) — autentificare OIDC alternativă pentru Vault și ArgoCD, adăugată aditiv, fără să elimine metodele de autentificare existente (token root/userpass pentru Vault, admin local pentru ArgoCD rămân funcționale).

demo-app — deployment gestionat integral prin ArgoCD, pe bază de manifeste din GitLab:

Versiune de dezvoltare (dev-demo-app) — deploy automat la push pe orice branch în afară de master, fără aprobare
postgressql - db pentru demo-app, instalat ca statefulsets cu storage localhost, am evitat nfs din motive de bune practici, db are nevoie de acces exclusiv, latenta.
Niciun secret nu există în git — manifestele conțin doar referințe către Vault, materializate în cluster de External Secrets Operator
Adnotație Reloader — repornire automată (rolling restart) a pod-urilor la orice schimbare a secretului
Network Policy — restricționează traficul demo-app doar către baza de date și gateway, nimic altceva
External Secrets Operator (ESO) — sincronizează secretele din Vault în Secret-uri native Kubernetes, la interval configurabil.
Reloader — monitorizează Secret-urile/ConfigMap-urile și declanșează automat rolling restart pe pod-urile care le folosesc.

Cilium — CNI-ul clusterului:

Criptare transparentă a traficului intern, atât pod-to-pod cât și node-to-node (WireGuard)
L2 Announcements — pe infrastructură bare-metal/libvirt nu există un controller de LoadBalancer din cloud; Cilium alocă IP-uri pentru Service-urile de tip LoadBalancer dintr-un pool dedicat (CiliumLoadBalancerIPPool, un interval liber din rețeaua clusterului) și le anunță prin ARP pe toate nodurile (CiliumL2AnnouncementPolicy) - fără asta, IP-ul ar fi alocat dar nimeni n-ar răspunde la ARP pentru el. Fără node selector - topologie HA simetrică, toate nodurile pot răspunde
Gateway API — Cilium implementează nativ Gateway API (gatewayAPI: enabled), punctul unic de intrare HTTPS pentru toate aplicațiile expuse din cluster (hostname wildcard *.kube-dev.local). TLS se termină aici, cu certificat provizionat automat de cert-manager din CA-ul intern; portul 80 doar redirectă către HTTPS. IP-ul extern al gateway-ului vine din același pool L2 de mai sus
Colector OTel (in-cluster) — trei roluri distincte:

Kafka, Keycloak și Redis  - instalate ca statefulsets cu storage localhost, evita nfs

Proxy OTLP (gRPC/HTTP) — retransmite trace-urile și metricile instrumentate de demo-app către SigNoz
Colector de metrici de cluster — stare noduri/pod-uri/deployment-uri, direct din API-ul Kubernetes (rol echivalent kube-state-metrics, fără a instala o componentă separată)
DaemonSet hostmetrics — metrici de infrastructură per nod (CPU, RAM, disc), la nivel de gazdă.

ATENTIONARE !!!
La instalare o sa vrea sa faca urmatoarele inregistrari in /etc/hosts:

10.10.10.192 hubble.kube-dev.local
10.10.10.192 demo.kube-dev.local
10.10.10.20 gitlab.kube-dev.local
10.10.10.192 argocd.kube-dev.local
10.10.10.192 keycloak.kube-dev.local
10.10.10.20 vault.kube-dev.local
10.10.10.20 signoz.kube-dev.local


Instalare

git clone https://github.com/criflor/proiect.git
cd proiect
sudo ./setup_hosts.sh
./install.sh


Cheia Vault (unseal + root token)

Generată automat, o singură dată, la prima instalare a Vault-ului. E scrisă în:


suport_vm/.vault_init.json

Conține cheia de unseal și token-ul root (JSON simplu). E singurul fișier secret local din tot proiectul — orice altă parolă/token generat ulterior (GitLab, SigNoz, Keycloak, ArgoCD) e scris direct în Vault, nu pe disc. Fișierul e .gitignore-uit — nu ajunge niciodată în repo.

redis si kafka nu sunt expuse deoarece nu au autentificare
hubble este expus de curiozitate

Lista endpoint-uri

URL                             USERNAME                                        Rol
gitlab.kube-dev.local          appadm,root                                      ui
gitlab.kube-dev.local:5050     registry_deploy_token                            pull imagini in cluster
vault.kube-dev.local:8200      root (token), appadm (parola), ssoadm(parola)    ui
signoz.kube-dev.local:8443     admin@kube-dev.local                             ui
argocd.kube-dev.local          appadm (parola) ssoadm (parola)                  ui
demo.kube-dev.local            appadm                                           ui
dev-demo.kube-dev.local        appadm                                           ui
keycloak.kube-dev.local        admin, ssoadm                                    ui
hubble.kube-dev.local          -                                                ui