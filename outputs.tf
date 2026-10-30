output "frontend_url" {
  description = "Where the frontend listens on the server host, for the reverse proxy in front of it. Null without a server."
  value       = length(var.servers) == 0 ? null : local.local_url
}

output "server_address" {
  description = "Address the agents report to."
  value       = local.server_address
}

output "psk_file" {
  description = "Path of each agent's pre-shared key on its own host, when agent_psk is on. Its identity is the agent's name."
  value       = var.agent_psk ? local.psk_file : null
}
