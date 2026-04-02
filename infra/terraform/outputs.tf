output "server_ip" {
  description = "Public IPv4 address of the server"
  value       = hcloud_server.accounting.ipv4_address
}

output "server_status" {
  description = "Server status"
  value       = hcloud_server.accounting.status
}
