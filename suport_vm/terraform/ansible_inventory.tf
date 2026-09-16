# Generează automat inventarul Ansible pentru acest deployment - aceeași
# abordare ca la clusterul k3s (terraform/ansible_inventory.tf), dar complet
# independentă (fișier separat, fără nicio legătură de stare cu acel proiect).
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory.ini"

  content = <<-EOT
    [suport]
    ${var.hostname} ansible_host=${split("/", var.ip)[0]}

    [suport:vars]
    ansible_user=admin
    ansible_ssh_private_key_file=${trimsuffix(local.ssh_public_key_path, ".pub")}
    ansible_python_interpreter=/usr/bin/python3
  EOT
}
