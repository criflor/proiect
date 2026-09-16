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

# Rețeaua "k8s-cluster" e partajată cu proiectul kubernetes_cluster/terraform
# (clusterul k3s are noduri în aceeași rețea) - oricare dintre cele două
# proiecte poate rula primul, de-aia nu presupunem că celălalt a creat-o deja:
# verificăm direct în libvirt (nu doar în state-ul acestui proiect) și o
# creăm aici doar dacă lipsește cu adevărat.
data "external" "k8s_network_check" {
  program = ["bash", "-c", "virsh -c qemu:///system net-info ${var.shared_network_name} >/dev/null 2>&1 && echo '{\"exists\":\"true\"}' || echo '{\"exists\":\"false\"}'"]
}

locals {
  k8s_network_exists = data.external.k8s_network_check.result.exists == "true"

  # Marker persistent - "am creat EU rețeaua asta" - necesar pentru
  # idempotență: fără el, la o a doua rulare a acestui proiect, verificarea
  # de mai sus ar găsi rețeaua deja existentă (creată de proiectul însuși la
  # prima rulare) și ar decide count=0 -> Terraform și-ar distruge propria
  # rețea, ruptă de sub VM-ul care rulează pe ea (întâlnit practic). Marker-ul
  # face distincția: "nu există încă" (o creez) vs. "există și e a mea" (o
  # păstrez) vs. "există și e a celuilalt proiect" (nu o creez, count 0).
  network_owned_marker = "${path.module}/.k8s_network_owned"
  network_owned         = fileexists(local.network_owned_marker)
  create_k8s_network    = local.network_owned || !local.k8s_network_exists

  # Implicit, relativ la rădăcina acestui checkout (nu la "rasirom" hardcodat)
  # - var.ssh_public_key_path/var.base_image_path rămân suprascriabile explicit
  # dacă cineva chiar vrea altă cale.
  ssh_public_key_path = var.ssh_public_key_path != "" ? var.ssh_public_key_path : abspath("${path.module}/../../ssh/id_ed25519.pub")
  base_image_path      = var.base_image_path != "" ? var.base_image_path : abspath("${path.module}/../../iso/noble-server-cloudimg-amd64.img")
  vms_pool_path         = abspath("${path.module}/../../vms-suport")
}

# Aceeași definiție (nume, mod, gateway/prefix) ca în kubernetes_cluster/terraform/main.tf
# - dacă acest proiect rulează primul, creează exact rețeaua pe care clusterul
# k3s o va găsi deja existentă (count 0 acolo) la rularea lui ulterioară.
resource "libvirt_network" "k8s" {
  count = local.create_k8s_network ? 1 : 0

  name = var.shared_network_name

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

# Scris o singură dată, imediat ce rețeaua e creată de ACEST proiect -
# rămâne pe disc pentru totdeauna (nu se șterge la niciun apply ulterior),
# ca planurile viitoare să știe fără echivoc "asta e rețeaua mea".
resource "local_file" "k8s_network_owned_marker" {
  count    = length(libvirt_network.k8s) > 0 ? 1 : 0
  filename = local.network_owned_marker
  content  = "Rețeaua \"${var.shared_network_name}\" a fost creată de acest proiect (suport_vm/terraform) - nu șterge acest fișier.\n"
}

# Storage pool dedicat acestui deployment (separat de pool-ul "rasirom" al
# clusterului k3s) - fișierele lui trăiesc într-un director propriu.
resource "libvirt_pool" "suport" {
  name = "suport"
  type = "dir"

  target = {
    path = local.vms_pool_path
  }
}

# Imagine de bază, folosită DOAR ca backing_store pentru discul de sistem.
# Important: providerul respectă capacity > dimensiunea sursei doar pentru
# volume cu backing_store - un volum creat direct din create.content ignoră
# capacity și rămâne la mărimea imaginii sursă (verificat practic - vezi
# documentația, secțiunea "Probleme întâlnite").
resource "libvirt_volume" "base" {
  name = "${var.hostname}-base.qcow2"
  pool = libvirt_pool.suport.name

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

# Disc de sistem propriu-zis (COW peste imaginea de bază) - aceeași abordare
# ca la discurile de sistem ale nodurilor clusterului k3s.
resource "libvirt_volume" "os_disk" {
  name     = "${var.hostname}.qcow2"
  pool     = libvirt_pool.suport.name
  capacity = var.os_disk_size_gib * 1024 * 1024 * 1024

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = libvirt_volume.base.path
    format = {
      type = "qcow2"
    }
  }
}

# Cele 3 discuri de date - goale, fără backing_store/create, deci Terraform nu
# le recreează niciodată la reaplicare (protejează datele GitLab/NFS/SigNoz).
# Partiționarea lor (LVM) se face în cloud-init, o singură dată, la prima
# pornire (vezi user_data mai jos).
resource "libvirt_volume" "data_gitlab" {
  name     = "${var.hostname}-data-gitlab.qcow2"
  pool     = libvirt_pool.suport.name
  capacity = var.data_gitlab_size_gib * 1024 * 1024 * 1024

  target = {
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_volume" "data_nfs" {
  name     = "${var.hostname}-data-nfs.qcow2"
  pool     = libvirt_pool.suport.name
  capacity = var.data_nfs_size_gib * 1024 * 1024 * 1024

  target = {
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_volume" "data_signoz" {
  name     = "${var.hostname}-data-signoz.qcow2"
  pool     = libvirt_pool.suport.name
  capacity = var.data_signoz_size_gib * 1024 * 1024 * 1024

  target = {
    format = {
      type = "qcow2"
    }
  }
}

# Cloud-init: hostname, IP static, user admin (aceeași abordare ca la
# clusterul k3s), plus configurarea LVM pentru cele 3 discuri de date.
resource "libvirt_cloudinit_disk" "init" {
  name = "${var.hostname}-init.iso"

  meta_data = <<-EOT
    instance-id: ${var.hostname}
    local-hostname: ${var.hostname}
  EOT

  user_data = <<-EOT
    #cloud-config
    hostname: ${var.hostname}
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
      - lvm2

    # LVM pe cele 3 discuri de date - un VG + un LV separat per componentă,
    # ca fiecare să poată fi extins independent mai târziu (pvcreate pe un
    # disc nou + vgextend + lvextend + resize2fs), fără să atingă celelalte.
    # Idempotent (verifică înainte de a crea) - rulează o singură dată la
    # prima pornire, dar suportă și o rulare manuală repetată fără efecte
    # secundare.
    runcmd:
      - [ bash, -c, "pvs /dev/vdb >/dev/null 2>&1 || pvcreate /dev/vdb" ]
      - [ bash, -c, "vgs vg_gitlab >/dev/null 2>&1 || vgcreate vg_gitlab /dev/vdb" ]
      - [ bash, -c, "lvs vg_gitlab/lv_gitlab >/dev/null 2>&1 || lvcreate -l 100%FREE -n lv_gitlab vg_gitlab" ]
      - [ bash, -c, "blkid /dev/vg_gitlab/lv_gitlab >/dev/null 2>&1 || mkfs.ext4 /dev/vg_gitlab/lv_gitlab" ]

      - [ bash, -c, "pvs /dev/vdc >/dev/null 2>&1 || pvcreate /dev/vdc" ]
      - [ bash, -c, "vgs vg_nfs >/dev/null 2>&1 || vgcreate vg_nfs /dev/vdc" ]
      - [ bash, -c, "lvs vg_nfs/lv_nfs >/dev/null 2>&1 || lvcreate -l 100%FREE -n lv_nfs vg_nfs" ]
      - [ bash, -c, "blkid /dev/vg_nfs/lv_nfs >/dev/null 2>&1 || mkfs.ext4 /dev/vg_nfs/lv_nfs" ]

      - [ bash, -c, "pvs /dev/vdd >/dev/null 2>&1 || pvcreate /dev/vdd" ]
      - [ bash, -c, "vgs vg_signoz >/dev/null 2>&1 || vgcreate vg_signoz /dev/vdd" ]
      - [ bash, -c, "lvs vg_signoz/lv_signoz >/dev/null 2>&1 || lvcreate -l 100%FREE -n lv_signoz vg_signoz" ]
      - [ bash, -c, "blkid /dev/vg_signoz/lv_signoz >/dev/null 2>&1 || mkfs.ext4 /dev/vg_signoz/lv_signoz" ]

      - [ mkdir, -p, /data/gitlab ]
      - [ mkdir, -p, /data/nfs ]
      - [ mkdir, -p, /data/signoz ]

      - [ bash, -c, "grep -q /dev/vg_gitlab/lv_gitlab /etc/fstab || echo '/dev/mapper/vg_gitlab-lv_gitlab /data/gitlab ext4 defaults,nofail 0 2' >> /etc/fstab" ]
      - [ bash, -c, "grep -q /dev/vg_nfs/lv_nfs /etc/fstab || echo '/dev/mapper/vg_nfs-lv_nfs /data/nfs ext4 defaults,nofail 0 2' >> /etc/fstab" ]
      - [ bash, -c, "grep -q /dev/vg_signoz/lv_signoz /etc/fstab || echo '/dev/mapper/vg_signoz-lv_signoz /data/signoz ext4 defaults,nofail 0 2' >> /etc/fstab" ]

      - [ mount, -a ]
  EOT

  network_config = <<-EOT
    version: 2
    ethernets:
      all-en:
        match:
          name: "en*"
        dhcp4: false
        addresses:
          - ${var.ip}
        routes:
          - to: default
            via: ${var.gateway}
        nameservers:
          addresses: [8.8.8.8, 1.1.1.1]
  EOT
}

# ISO-ul cloud-init trebuie încărcat explicit ca volum în pool, ca să poată fi atașat la domeniu
resource "libvirt_volume" "init_vol" {
  name = "${var.hostname}-init.iso"
  pool = libvirt_pool.suport.name

  target = {
    format = {
      type = "iso"
    }
  }

  create = {
    content = {
      url = libvirt_cloudinit_disk.init.path
    }
  }
}

resource "libvirt_domain" "suport" {
  name        = var.hostname
  type        = "kvm"
  running     = true
  memory      = var.memory_mib
  memory_unit = "MiB"
  vcpu        = var.vcpu

  # Fără asta, libvirt expune un CPU generic minim ("QEMU Virtual CPU"), fără
  # AVX/AVX2 - deși host-ul le are. ClickHouse (folosit de SigNoz, cerința
  # 10) are căi de cod optimizate SIMD care se comportă defect pe acest
  # profil minim (erori "Couldn't allocate N bytes" la anumite interogări cu
  # funcții JSON) - verificat practic, vezi documentația.
  cpu = {
    mode = "host-passthrough"
  }

  os = {
    type      = "hvm"
    type_arch = "x86_64"
  }

  devices = {
    disks = [
      {
        driver = { type = "qcow2" }
        source = {
          volume = {
            pool   = libvirt_pool.suport.name
            volume = libvirt_volume.os_disk.name
          }
        }
        target = { dev = "vda", bus = "virtio" }
      },
      {
        driver = { type = "qcow2" }
        source = {
          volume = {
            pool   = libvirt_pool.suport.name
            volume = libvirt_volume.data_gitlab.name
          }
        }
        target = { dev = "vdb", bus = "virtio" }
      },
      {
        driver = { type = "qcow2" }
        source = {
          volume = {
            pool   = libvirt_pool.suport.name
            volume = libvirt_volume.data_nfs.name
          }
        }
        target = { dev = "vdc", bus = "virtio" }
      },
      {
        driver = { type = "qcow2" }
        source = {
          volume = {
            pool   = libvirt_pool.suport.name
            volume = libvirt_volume.data_signoz.name
          }
        }
        target = { dev = "vdd", bus = "virtio" }
      },
      {
        device    = "cdrom"
        read_only = true
        driver    = { type = "raw" }
        source = {
          volume = {
            pool   = libvirt_pool.suport.name
            volume = libvirt_volume.init_vol.name
          }
        }
        target = { dev = "hdd", bus = "ide" }
      }
    ]

    interfaces = [
      {
        model = { type = "virtio" }
        source = {
          network = {
            network = var.shared_network_name
          }
        }
      }
    ]

    consoles = [
      {
        target = { type = "serial", port = 0 }
      }
    ]

    graphics = [
      {
        spice = { auto_port = true }
      }
    ]
  }

  # "network" de mai sus e o referință prin nume (var.shared_network_name),
  # nu prin atributul resursei - Terraform nu ar ști altfel că domeniul
  # trebuie creat DUPĂ rețea (când rețeaua chiar se creează aici, adică
  # local.k8s_network_exists == false).
  depends_on = [libvirt_network.k8s]
}

output "suport_vm_ip" {
  value = split("/", var.ip)[0]
}
