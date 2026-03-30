############################################################
# Cloudflare Tunnel + DNS
############################################################
# this is a test for github workflow and github self hosted runner
resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
  account_id = var.cloudflare_account_id
  name       = "homelab-k8s"
}

# DNS CNAME records pointing to the tunnel
resource "cloudflare_dns_record" "blog" {
  zone_id = var.cloudflare_zone_id
  name    = "blog"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "grafana" {
  zone_id = var.cloudflare_zone_id
  name    = "grafana"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "argocd" {
  zone_id = var.cloudflare_zone_id
  name    = "argocd"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "landing" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}

# Configure tunnel ingress rules via API (v5 provider has no config resource)
resource "terraform_data" "tunnel_config" {
  input = {
    account_id = var.cloudflare_account_id
    tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
    api_token  = var.cloudflare_api_token
  }

  provisioner "local-exec" {
    command = <<EOT
curl -sf -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/${self.input.account_id}/cfd_tunnel/${self.input.tunnel_id}/configurations" \
  -H "Authorization: Bearer ${self.input.api_token}" \
  -H "Content-Type: application/json" \
  -d '{"config":{"ingress":[{"hostname":"lennardjohn.org","service":"http://ingress-nginx-controller.ingress-nginx.svc.cluster.local"},{"hostname":"blog.lennardjohn.org","service":"http://ingress-nginx-controller.ingress-nginx.svc.cluster.local"},{"hostname":"grafana.lennardjohn.org","service":"http://ingress-nginx-controller.ingress-nginx.svc.cluster.local"},{"hostname":"argocd.lennardjohn.org","service":"http://ingress-nginx-controller.ingress-nginx.svc.cluster.local"},{"service":"http_status:404"}]}}' \
  | jq -e '.success == true'
EOT
  }
}
