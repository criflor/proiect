variable "ssh_public_key_path" {
  description = "Calea către cheia publică SSH adăugată userului admin"
  type        = string
  # Cheie dedicată proiectului (ssh/generate_ssh_key.yml), nu mai cea
  # personală din ~/.ssh - se aplică abia la o recreare a VM-ului (cloud-init
  # rulează o singură dată, la prima pornire).
  default = ""
}

variable "hostname" {
  description = "Hostname-ul VM-ului de suport"
  type        = string
  default     = "suport-vm"
}

variable "ip" {
  description = "Adresa IP statică (CIDR), pe aceeași rețea ca și clusterul k3s"
  type        = string
  default     = "10.10.10.20/24"
}

variable "gateway" {
  description = "Gateway-ul rețelei (adresa bridge-ului k8s-cluster, creat de proiectul terraform/ al clusterului)"
  type        = string
  default     = "10.10.10.1"
}

# Rețeaua "k8s-cluster" e creată de proiectul terraform/ al clusterului
# (resursă libvirt, nu Terraform state) - VM-ul de suport se atașează la ea
# prin nume, ca un deployment separat, independent de acel state.
variable "shared_network_name" {
  description = "Numele rețelei libvirt existente, partajate cu clusterul k3s"
  type        = string
  default     = "k8s-cluster"
}

# Trebuie să fie identice cu kubernetes_cluster/terraform/variables.tf - dacă
# rețeaua nu există încă și o creează acest proiect (vezi main.tf), clusterul
# k3s trebuie să găsească exact aceeași rețea la rularea lui ulterioară.
variable "k8s_network_gateway" {
  description = "Adresa gateway-ului (= adresa bridge-ului) pentru rețeaua partajată"
  type        = string
  default     = "10.10.10.1"
}

variable "k8s_network_prefix" {
  description = "Prefixul CIDR al rețelei partajate"
  type        = number
  default     = 24
}

# Imaginea de bază e cea deja descărcată de proiectul kubernetes_cluster/terraform/
# al clusterului (același fișier .img, deci fără o a doua descărcare) - dar
# volumul propriu-zis (pool-ul "suport") e independent de acela.
variable "base_image_path" {
  description = "Calea locală către imaginea cloud Ubuntu, folosită ca sursă pentru discul de sistem"
  type        = string
  default     = ""
}

variable "memory_mib" {
  description = "Memoria alocată VM-ului de suport, în MiB"
  type        = number
  # Ridicat de la 8 la 12 GiB - GitLab singur folosește ~4-5 GiB, iar stack-ul
  # SigNoz (ClickHouse + otel-collector + query-service) are nevoie de o marjă
  # reală, nu de resturile rămase după GitLab.
  default = 12288
}

variable "vcpu" {
  description = "Numărul de vCPU alocate VM-ului de suport"
  type        = number
  default     = 4
}

variable "os_disk_size_gib" {
  description = "Dimensiunea discului de sistem, în GiB"
  type        = number
  default     = 20
}

variable "data_gitlab_size_gib" {
  description = "Dimensiunea discului dedicat datelor GitLab (repo-uri, registry), în GiB"
  type        = number
  default     = 25
}

variable "data_nfs_size_gib" {
  description = "Dimensiunea discului dedicat exporturilor NFS, în GiB"
  type        = number
  default     = 15
}

variable "data_signoz_size_gib" {
  description = "Dimensiunea discului dedicat datelor SigNoz (ClickHouse), în GiB"
  type        = number
  default     = 15
}
