variable "bastion_ip" {
  type        = string
  description = "Public IP of bastion host"
}

variable "ssh_private_key_path" {
  type        = string
  description = "Path to SSH private key for provisioning"
}

variable "wireguard_port" {
  type    = number
  default = 51820
}

variable "wireguard_subnet" {
  type    = string
  default = "10.10.0.0/24"
}

resource "null_resource" "wireguard_setup" {
  connection {
    type        = "ssh"
    host        = var.bastion_ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
      "apt-get update && apt-get install -y wireguard",
      "wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key",
      "chmod 600 /etc/wireguard/private.key",
      "cat > /etc/wireguard/wg0.conf <<'WGEOF'",
      "[Interface]",
      "Address = ${cidrhost(var.wireguard_subnet, 1)}/24",
      "ListenPort = ${var.wireguard_port}",
      "PrivateKey = $(cat /etc/wireguard/private.key)",
      "PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE",
      "PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE",
      "WGEOF",
      "systemctl enable --now wg-quick@wg0",
    ]
  }
}

output "wireguard_public_key_command" {
  value = "ssh root@${var.bastion_ip} cat /etc/wireguard/public.key"
}
