resource "hcloud_rdns" "accounting_ipv4" {
  server_id  = hcloud_server.accounting.id
  ip_address = hcloud_server.accounting.ipv4_address
  dns_ptr    = var.domain
}
