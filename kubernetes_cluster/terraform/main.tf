terraform {
  required_version = ">= 1.5.0"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "= 0.9.9"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}

provider "libvirt" {
  uri = "qemu:///system"
}

# Rețeaua "k8s-cluster" e partajată cu proiectul suport_vm/terraform (VM-ul de
# suport are o interfață în aceeași rețea) - oricare dintre cele două proiecte
# poate rula primul, de-aia nu presupunem că celălalt a creat-o deja: verificăm
# direct în libvirt (nu doar în state-ul acestui proiect) și o creăm aici doar
# dacă lipsește cu adevărat.
data "external" "k8s_network_check" {
  program = ["bash", "-c", "virsh -c qemu:///system net-info k8s-cluster >/dev/null 2>&1 && echo '{\"exists\":\"true\"}' || echo '{\"exists\":\"false\"}'"]
}

locals {
  k8s_network_name   = "k8s-cluster"
  k8s_network_exists = data.external.k8s_network_check.result.exists == "true"

  # Marker persistent - vezi explicația din suport_vm/terraform/main.tf: fără
  # el, la o a doua rulare, verificarea de mai jos ar găsi rețeaua deja
  # existentă (creată de acest proiect la prima rulare) și ar decide count=0
  # -> Terraform și-ar distruge propria rețea, ruptă de sub VM-urile clusterului.
  network_owned_marker = "${path.module}/.k8s_network_owned"
  network_owned         = fileexists(local.network_owned_marker)
  create_k8s_network    = local.network_owned || !local.k8s_network_exists

  # Implicit, relativ la rădăcina acestui checkout (nu la "rasirom" hardcodat)
  # - var.ssh_public_key_path rămâne suprascriabilă explicit dacă e nevoie.
  ssh_public_key_path = var.ssh_public_key_path != "" ? var.ssh_public_key_path : abspath("${path.module}/../../ssh/id_ed25519.pub")
  base_image_path      = abspath("${path.module}/../../iso/noble-server-cloudimg-amd64.img")
  vms_pool_path         = abspath("${path.module}/../../vms")
}

# Storage pool
resource "libvirt_pool" "rasirom" {
  name = "rasirom"
  type = "dir"

  target = {
    path = local.vms_pool_path
  }
}

# Imaginea de bază, partajată (read-only) de toate VM-urile clusterului via backing_store (COW)
resource "libvirt_volume" "ubuntu_base" {
  name = "ubuntu-base.qcow2"
  pool = libvirt_pool.rasirom.name

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = local.base_image_path
    }
  }
}

# Rețea dedicată clusterului (izolată de rețeaua "default" a gazdei, fără DHCP - IP-urile sunt statice)
# count 0 dacă rețeaua a fost deja creată de celălalt proiect (suport_vm/terraform) - vezi data.external de mai sus.
resource "libvirt_network" "k8s" {
  count = local.create_k8s_network ? 1 : 0

  name = local.k8s_network_name

  forward = {
    mode = "nat"
  }

  ips = [
    {
      address = var.k8s_network_gateway
      prefix  = var.k8s_network_prefix
    }
  ]
}

# Scris o singură dată, imediat ce rețeaua e creată de ACEST proiect - rămâne
# pe disc pentru totdeauna, ca planurile viitoare să știe fără echivoc "asta e
# rețeaua mea" (vezi explicația din suport_vm/terraform/main.tf).
resource "local_file" "k8s_network_owned_marker" {
  count    = length(libvirt_network.k8s) > 0 ? 1 : 0
  filename = local.network_owned_marker
  content  = "Rețeaua \"${local.k8s_network_name}\" a fost creată de acest proiect (kubernetes_cluster/terraform) - nu șterge acest fișier.\n"
}

# Disk de sistem (OS), câte unul per VM, toate pornind din aceeași imagine de bază
resource "libvirt_volume" "os_disk" {
  for_each = var.vms

  name     = "${each.key}.qcow2"
  pool     = libvirt_pool.rasirom.name
  capacity = var.os_disk_size_gib * 1024 * 1024 * 1024

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = libvirt_volume.ubuntu_base.path
    format = {
      type = "qcow2"
    }
  }
}

# Disk suplimentar de date, câte unul per VM (minimum 2 GiB), gol - fără backing_store/create,
# deci Terraform nu îl recreează și nu îi rescrie conținutul la reaplicări ulterioare.
resource "libvirt_volume" "data_disk" {
  for_each = var.vms

  name     = "${each.key}-data.qcow2"
  pool     = libvirt_pool.rasirom.name
  capacity = var.data_disk_size_gib * 1024 * 1024 * 1024

  target = {
    format = {
      type = "qcow2"
    }
  }
}

# Cloud-init per VM: hostname, IP/gateway static, user admin, plus partiționarea și montarea
# persistentă a discului de date (/dev/vdb -> /mnt/data + /var/www/data-share).
resource "libvirt_cloudinit_disk" "init" {
  for_each = var.vms

  name = "${each.key}-init.iso"

  meta_data = <<-EOT
    instance-id: ${each.key}
    local-hostname: ${each.value.hostname}
  EOT

  user_data = <<-EOT
    #cloud-config
    hostname: ${each.value.hostname}
    manage_etc_hosts: true
    users:
      - name: admin
        no_user_group: true
        sudo: ALL=(ALL) NOPASSWD:ALL
        shell: /bin/bash
        lock_passwd: true
        ssh_authorized_keys:
          - ${trimspace(file(pathexpand(local.ssh_public_key_path)))}
    package_update: true
    packages:
      - curl
      - git
      - vim

    # Partiționează discul de date /dev/vdb în 2 partiții egale.
    # overwrite: false => dacă discul are deja un tabel de partiții, cloud-init NU îl atinge:
    # rerularea automatizării (sau un reboot) nu distruge datele existente.
    disk_setup:
      /dev/vdb:
        table_type: gpt
        layout: [50, 50]
        overwrite: false

    fs_setup:
      - device: /dev/vdb1
        filesystem: ext4
        overwrite: false
      - device: /dev/vdb2
        filesystem: ext4
        overwrite: false

    # Intrări persistente în /etc/fstab - montarea supraviețuiește repornirilor VM-ului.
    mounts:
      - [/dev/vdb1, /mnt/data, ext4, "defaults,nofail", "0", "2"]
      - [/dev/vdb2, /var/www/data-share, ext4, "defaults,nofail", "0", "2"]
  EOT

  network_config = <<-EOT
    version: 2
    ethernets:
      all-en:
        match:
          name: "en*"
        dhcp4: false
        addresses:
          - ${each.value.ip}
        routes:
          - to: default
            via: ${each.value.gateway}
        nameservers:
          addresses: [8.8.8.8, 1.1.1.1]
  EOT
}

# ISO-ul cloud-init trebuie încărcat explicit ca volum în pool, ca să poată fi atașat la domeniu
resource "libvirt_volume" "init_vol" {
  for_each = var.vms

  name = "${each.key}-init.iso"
  pool = libvirt_pool.rasirom.name

  target = {
    format = {
      type = "iso"
    }
  }

  create = {
    content = {
      url = libvirt_cloudinit_disk.init[each.key].path
    }
  }
}

# VM-urile clusterului Kubernetes
resource "libvirt_domain" "vm" {
  for_each = var.vms

  name        = each.key
  type        = "kvm"
  running     = true
  memory      = each.value.memory_mib
  memory_unit = "MiB"
  vcpu        = 2

  os = {
    type      = "hvm"
    type_arch = "x86_64"
  }

  devices = {
    disks = [
      {
        driver = {
          type = "qcow2"
        }
        source = {
          volume = {
            pool   = libvirt_pool.rasirom.name
            volume = libvirt_volume.os_disk[each.key].name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        driver = {
          type = "qcow2"
        }
        source = {
          volume = {
            pool   = libvirt_pool.rasirom.name
            volume = libvirt_volume.data_disk[each.key].name
          }
        }
        target = {
          dev = "vdb"
          bus = "virtio"
        }
      },
      {
        device    = "cdrom"
        read_only = true
        driver = {
          type = "raw"
        }
        source = {
          volume = {
            pool   = libvirt_pool.rasirom.name
            volume = libvirt_volume.init_vol[each.key].name
          }
        }
        target = {
          dev = "hdd"
          bus = "ide"
        }
      }
    ]

    interfaces = [
      {
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = local.k8s_network_name
          }
        }
      }
    ]

    consoles = [
      {
        target = {
          type = "serial"
          port = 0
        }
      }
    ]

    graphics = [
      {
        spice = {
          auto_port = true
        }
      }
    ]
  }

  # "network" de mai sus e o referință prin nume (local.k8s_network_name),
  # nu prin atributul resursei - Terraform nu ar ști altfel că domeniul
  # trebuie creat DUPĂ rețea (când rețeaua chiar se creează aici, adică
  # local.k8s_network_exists == false).
  depends_on = [libvirt_network.k8s]
}

output "vm_ips" {
  description = "Hostname -> adresă IP statică pentru fiecare VM din cluster"
  value = {
    for key, vm in var.vms : key => split("/", vm.ip)[0]
  }
}
