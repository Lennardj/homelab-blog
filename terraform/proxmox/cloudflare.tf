############################################################
# Cloudflare Tunnel + DNS
############################################################

resource "random_id" "tunnel_secret" {
  byte_length = 35
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
  account_id = var.cloudflare_account_id
  name       = "homelab-k8s"
  secret     = random_id.tunnel_secret.b64_std
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id

  config {
    ingress_rule {
      hostname = "blog.${var.domain_name}"
      service  = "http://ingress-nginx-controller.ingress-nginx.svc.cluster.local"
    }

    ingress_rule {
      hostname = "grafana.${var.domain_name}"
      service  = "http://ingress-nginx-controller.ingress-nginx.svc.cluster.local"
    }

    # catch-all: reject everything else
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# DNS CNAME records pointing to the tunnel
resource "cloudflare_dns_record" "blog" {
  zone_id = var.cloudflare_zone_id
  name    = "blog"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
}

resource "cloudflare_dns_record" "grafana" {
  zone_id = var.cloudflare_zone_id
  name    = "grafana"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
}
