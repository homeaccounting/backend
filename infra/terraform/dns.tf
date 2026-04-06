resource "hcloud_rdns" "main_ipv4" {
  server_id  = hcloud_server.main.id
  ip_address = hcloud_server.main.ipv4_address
  dns_ptr    = var.domain
}
