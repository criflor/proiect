# Generează automat inventarul Ansible din aceleași variabile folosite pentru VM-uri,
# ca să nu existe drift între infrastructura Terraform și inventarul Ansible.
resource "local_file" "ansible_inventory" {
  filename = "${path.module}/../ansible/inventory.ini"

  content = <<-EOT
    [k8s_cluster]
    %{for key, vm in var.vms~}
    ${key} ansible_host=${split("/", vm.ip)[0]}
    %{endfor~}

    [k8s_cluster:vars]
    ansible_user=admin
    ansible_ssh_private_key_file=${trimsuffix(local.ssh_public_key_path, ".pub")}
    ansible_python_interpreter=/usr/bin/python3
  EOT
}
