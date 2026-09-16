variable "ssh_public_key_path" {
  description = "Calea către cheia publică SSH adăugată userului admin"
  type        = string
  # Cheie dedicată proiectului (ssh/generate_ssh_key.yml), nu mai cea
  # personală din ~/.ssh - se aplică abia la o recreare a VM-urilor
  # (cloud-init rulează o singură dată, la prima pornire).
  default = ""
}

# Cele minimum 3 mașini virtuale ale clusterului Kubernetes.
# Pentru fiecare VM se configurează separat hostname-ul, adresa IP (CIDR) și gateway-ul.
variable "vms" {
  description = "Mașinile virtuale ale clusterului: hostname, adresă IP (CIDR), gateway și memorie pentru fiecare"
  type = map(object({
    hostname   = string
    ip         = string # ex: "10.10.10.10/24"
    gateway    = string
    memory_mib = optional(number, 2048)
  }))

  default = {
    "k3s-nd01" = {
      hostname = "k3s-nd01"
      ip       = "10.10.10.10/24"
      gateway  = "10.10.10.1"
      # Fiecare nod rulează, pe lângă workload-uri obișnuite, întregul plan
      # de control k3s (API server, scheduler, controller-manager, etcd
      # distribuit) - topologie simetrică, fără noduri dedicate exclusiv
      # control-plane sau exclusiv worker. 3 GiB s-au dovedit insuficiente
      # practic (nod ajuns NotReady sub sarcină simultană Kafka+Argo CD+
      # monitorizare, etcd cu latență de aplicare peste 2 minute) - ridicat
      # uniform la 4 GiB pe toate.
      memory_mib = 4096
    }
    "k3s-nd02" = {
      hostname   = "k3s-nd02"
      ip         = "10.10.10.11/24"
      gateway    = "10.10.10.1"
      memory_mib = 4096
    }
    "k3s-nd03" = {
      hostname   = "k3s-nd03"
      ip         = "10.10.10.12/24"
      gateway    = "10.10.10.1"
      memory_mib = 4096
    }
  }
}

variable "os_disk_size_gib" {
  description = "Dimensiunea (GiB) discului de sistem pentru fiecare VM"
  type        = number
  default     = 20
}

variable "data_disk_size_gib" {
  description = "Dimensiunea (GiB) discului suplimentar de date pentru fiecare VM (minimum 2 GiB, împărțit în 2 partiții)"
  type        = number
  default     = 4
}

# Rețea dedicată clusterului, separată de rețeaua implicită "default" a libvirt,
# ca să nu existe conflicte între adresele IP statice și pool-ul DHCP al gazdei.
variable "k8s_network_gateway" {
  description = "Adresa gateway-ului (= adresa bridge-ului) pentru rețeaua dedicată clusterului"
  type        = string
  default     = "10.10.10.1"
}

variable "k8s_network_prefix" {
  description = "Prefixul CIDR al rețelei dedicate clusterului"
  type        = number
  default     = 24
}
