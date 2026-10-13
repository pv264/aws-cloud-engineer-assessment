/**
 * Public ACM certificate for the API hostname, validated through Route 53 DNS.
 * ACM renews DNS-validated certificates automatically for as long as the validation
 * CNAME stays in place, so there is no expiry to babysit.
 */

resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name
  subject_alternative_names = var.subject_alternative_names
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  # Keyed by the configured hostnames (known at plan time) rather than by the
  # certificate's computed validation options, so the plan never has unknown keys.
  domains            = toset(concat([var.domain_name], var.subject_alternative_names))
  validation_options = { for option in aws_acm_certificate.this.domain_validation_options : option.domain_name => option }
}

resource "aws_route53_record" "validation" {
  for_each = local.domains

  zone_id         = var.hosted_zone_id
  name            = local.validation_options[each.key].resource_record_name
  type            = local.validation_options[each.key].resource_record_type
  records         = [local.validation_options[each.key].resource_record_value]
  ttl             = 300
  allow_overwrite = true # wildcard + apex names share one validation record
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]
}
