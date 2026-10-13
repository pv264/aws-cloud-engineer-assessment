"""Generates the architecture diagram as plain SVG (no external assets), so it can be
reviewed and changed like code:

    python architecture/generate_diagram.py > architecture/architecture-diagram.svg

architecture-diagram.png is a 2x render of that SVG (any headless browser, e.g.
Playwright's page.screenshot).
"""

import sys
from html import escape

W, H = 1720, 1130
FONT = "Helvetica, Arial, sans-serif"

C = {
    "compute": "#ED7100",
    "database": "#C925D1",
    "network": "#8C4FFF",
    "storage": "#7AA116",
    "security": "#DD344C",
    "mgmt": "#E7157B",
    "integration": "#E7157B",
    "devtools": "#3B48CC",
    "ink": "#232F3E",
    "muted": "#5F6B7A",
    "req": "#0972D3",
    "async": "#E7157B",
    "mgmtline": "#8D99A8",
}

out: list[str] = []
late: list[str] = []


def add(s: str) -> None:
    out.append(s)


def label(x, y, s, size=11, weight="bold", fill=C["ink"], anchor="start", halo="#FFFFFF", italic=False):
    style = ' font-style="italic"' if italic else ""
    late.append(
        f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" font-weight="{weight}" fill="{fill}" '
        f'text-anchor="{anchor}" stroke="{halo}" stroke-width="5" stroke-linejoin="round" paint-order="stroke"{style}>{escape(s)}</text>'
    )


def text(x, y, s, size=13, weight="normal", fill=C["ink"], anchor="start", italic=False):
    style = ' font-style="italic"' if italic else ""
    add(
        f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" font-weight="{weight}" '
        f'fill="{fill}" text-anchor="{anchor}"{style}>{escape(s)}</text>'
    )


def group(x, y, w, h, label, stroke, fill="none", dash=None, label_fill=None, rx=10):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="2"{d}/>')
    if label:
        text(x + 14, y + 22, label, size=14, weight="bold", fill=label_fill or stroke)


def node(x, y, w, h, title, sub=None, color=C["compute"], sub2=None):
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="#FFFFFF" stroke="{color}" stroke-width="1.6"/>')
    add(f'<rect x="{x}" y="{y}" width="7" height="{h}" rx="3" fill="{color}"/>')
    lines = [title] + ([sub] if sub else []) + ([sub2] if sub2 else [])
    total = 16 + (len(lines) - 1) * 15
    ty = y + h / 2 - total / 2 + 13
    text(x + w / 2 + 3, ty, title, size=13, weight="bold", anchor="middle")
    for i, line in enumerate(lines[1:], start=1):
        text(x + w / 2 + 3, ty + i * 15, line, size=11, fill=C["muted"], anchor="middle")


def arrow(points, color=C["req"], dash=None, width=2.2, label=None, label_pos=None, marker="req", both=False):
    d = " ".join(("M" if i == 0 else "L") + f"{px},{py}" for i, (px, py) in enumerate(points))
    da = f' stroke-dasharray="{dash}"' if dash else ""
    start = f' marker-start="url(#{marker}-start)"' if both else ""
    add(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}"{da} marker-end="url(#{marker})"{start}/>')
    if label:
        lx, ly = label_pos
        text(lx, ly, label, size=11, fill=color, anchor="middle", weight="bold")


add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">')
add("<defs>")
for name, color in (("req", C["req"]), ("async", C["async"]), ("mgmt", C["mgmtline"]), ("db", C["database"])):
    add(
        f'<marker id="{name}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
        f'<path d="M0,0 L10,5 L0,10 z" fill="{color}"/></marker>'
    )
    add(
        f'<marker id="{name}-start" viewBox="0 0 10 10" refX="1" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
        f'<path d="M0,0 L10,5 L0,10 z" fill="{color}"/></marker>'
    )
add("</defs>")
add(f'<rect width="{W}" height="{H}" fill="#FFFFFF"/>')

# ------------------------------------------------------------------ title
text(30, 40, "XYZZ Orders Platform: target architecture (production, us-east-1)", size=22, weight="bold")
text(30, 62, "Users → Route 53 → AWS WAF → ALB → ECS Fargate (3 AZs) → RDS Proxy → RDS PostgreSQL Multi-AZ; async work stays serverless", size=13, fill=C["muted"])

# ------------------------------------------------------------------ clients + CI/CD (outside AWS)
node(30, 120, 160, 64, "Users / clients", "web · mobile · partners", C["ink"])
group(20, 780, 190, 250, "CI/CD", C["devtools"], fill="#F5F6FF")
node(35, 815, 160, 56, "GitHub Actions", "test · build · scan", C["devtools"])
node(35, 885, 160, 56, "OIDC → IAM roles", "no long-lived keys", C["security"])
node(35, 955, 160, 56, "Terraform", "S3 state + lock", C["devtools"])

# ------------------------------------------------------------------ AWS cloud
group(220, 90, 1480, 1010, "AWS Cloud: region us-east-1 (one account per environment)", C["ink"], fill="#FBFBFC", label_fill=C["ink"])

# Edge column
group(240, 130, 190, 480, "Edge", C["network"], fill="#F7F3FF", dash="6 4")
node(255, 170, 160, 58, "Route 53", "api.xyzz.com (alias)", C["network"])
node(255, 245, 160, 58, "AWS WAF", "managed rules · rate limit", C["security"])
node(255, 320, 160, 58, "ACM", "TLS cert, auto-renew", C["security"])
node(255, 395, 160, 58, "Shield Standard", "L3/L4 DDoS", C["security"])
node(255, 470, 160, 70, "CloudFront + S3", "static assets (OAC)", C["network"], "cacheable GETs")

# VPC
VX, VY, VW, VH = 450, 130, 900, 650
group(VX, VY, VW, VH, "VPC 10.30.0.0/16", C["network"], fill="#FFFFFF")
node(VX + VW / 2 - 85, VY - 22, 170, 40, "Internet Gateway", None, C["network"])

azs = ["us-east-1a", "us-east-1b", "us-east-1c"]
col_w, col_gap = 280, 15
col_x = [VX + 20 + i * (col_w + col_gap) for i in range(3)]
for i, az in enumerate(azs):
    add(f'<rect x="{col_x[i]}" y="{VY + 36}" width="{col_w}" height="{VH - 50}" rx="8" fill="none" stroke="#B8C2CC" stroke-width="1.5" stroke-dasharray="5 4"/>')
    text(col_x[i] + col_w / 2, VY + 54, f"Availability Zone {az}", size=12, weight="bold", fill=C["muted"], anchor="middle")

bands = [
    ("Public subnets /24", VY + 64, 150, "#EAF7EA", "#7AA116"),
    ("Private app subnets /20", VY + 226, 200, "#EAF3FC", "#0972D3"),
    ("Private data subnets /24 (no internet route)", VY + 438, 196, "#FBEAFB", "#C925D1"),
]
for label_text, by, bh, fill, stroke in bands:
    for i in range(3):
        add(f'<rect x="{col_x[i] + 6}" y="{by}" width="{col_w - 12}" height="{bh}" rx="6" fill="{fill}" stroke="{stroke}" stroke-width="1" opacity="0.9"/>')
    label(col_x[0] + 14, by + 16, label_text, fill=stroke, halo=fill)

# public tier
alb_y = VY + 92
node(col_x[0] + 20, alb_y, 3 * col_w + 2 * col_gap - 40, 54, "Application Load Balancer",
     "HTTPS 443 (TLS 1.3/1.2) · HTTP→301 · least outstanding requests · weighted target groups (migration: Lambda ↔ ECS)", C["network"])
for i in range(3):
    node(col_x[i] + 125, VY + 160, 140, 44, "NAT gateway", None, C["network"])

# app tier
svc_y = VY + 262
label(VX + VW / 2 + 60, svc_y - 2, "ECS Fargate service · Graviton · 3–30 tasks · auto scaling (CPU + requests) · circuit-breaker rollback",
      size=12, fill=C["compute"], anchor="middle", halo="#EAF3FC")
for i in range(3):
    node(col_x[i] + 20, svc_y + 10, 115, 62, "Task", "Orders API", C["compute"], "FastAPI")
    node(col_x[i] + 145, svc_y + 10, 115, 62, "Task", "Orders API", C["compute"], "FastAPI")
for i in range(3):
    node(col_x[i] + 110, svc_y + 84, 160, 54, "VPC endpoints", "ECR · Logs · Secrets", C["network"], "STS · KMS")
label(VX + VW / 2, svc_y + 160, "Legacy Lambda (migration only) and async Lambdas also run in these subnets; they reach the DB only via RDS Proxy",
      size=11, weight="normal", fill=C["muted"], anchor="middle", halo="#EAF3FC", italic=True)

# data tier
proxy_y = VY + 462
node(col_x[0] + 20, proxy_y, 3 * col_w + 2 * col_gap - 40, 46, "RDS Proxy",
     "connection pooling + multiplexing · TLS required · IAM/secret auth", C["database"])
db_y = proxy_y + 66
node(col_x[0] + 35, db_y, 210, 76, "RDS PostgreSQL 17", "PRIMARY · KMS · TLS forced", C["database"], "PITR 14 d · Perf. Insights")
node(col_x[1] + 35, db_y, 210, 76, "RDS PostgreSQL 17", "STANDBY (Multi-AZ)", C["database"], "automatic failover")
add(f'<rect x="{col_x[2] + 35}" y="{db_y}" width="210" height="76" rx="8" fill="#FFFFFF" stroke="{C["database"]}" stroke-width="1.4" stroke-dasharray="5 4"/>')
text(col_x[2] + 140, db_y + 32, "Read replica", size=13, weight="bold", anchor="middle")
text(col_x[2] + 140, db_y + 50, "(added for read scaling)", size=11, fill=C["muted"], anchor="middle")
arrow([(col_x[0] + 245, db_y + 38), (col_x[1] + 35, db_y + 38)], color=C["database"], dash="6 4", marker="db", both=True)
text((col_x[0] + 245 + col_x[1] + 35) / 2, db_y + 30, "sync", size=11, fill=C["database"], anchor="middle", weight="bold")
arrow([(col_x[1] + 245, db_y + 38), (col_x[2] + 35, db_y + 38)], color=C["database"], dash="2 4", marker="db")
text((col_x[1] + 245 + col_x[2] + 35) / 2, db_y + 30, "async", size=11, fill=C["database"], anchor="middle", weight="bold")

# ------------------------------------------------------------------ regional services
RX = 1370
group(RX, 130, 315, 650, "Regional services", C["mgmt"], fill="#FFF6FA", dash="6 4")
regional = [
    ("Amazon ECR", "immutable tags · scan on push", C["compute"]),
    ("Secrets Manager", "RDS-managed, rotated secret", C["security"]),
    ("AWS KMS", "CMK per environment", C["security"]),
    ("CloudWatch", "logs · metrics · alarms · dashboard", C["mgmt"]),
    ("SNS → on-call", "alarm notifications", C["integration"]),
    ("Amazon S3", "assets (SSE-KMS) · ALB logs", C["storage"]),
    ("CloudTrail · GuardDuty", "Security Hub · Config", C["mgmt"]),
    ("IAM", "task roles · OIDC deploy roles", C["security"]),
]
for i, (t, s, col) in enumerate(regional):
    node(RX + 18, 165 + i * 75, 280, 60, t, s, col)

# ------------------------------------------------------------------ async / serverless
AY = 805
group(450, AY, 1235, 205, None, C["integration"], fill="#FFF6FA", dash="6 4")
text(480, AY + 145, "Event-driven and scheduled work: stays serverless", size=14, weight="bold", fill=C["integration"])
node(480, AY + 50, 190, 64, "Outbox relay", "order events (same txn)", C["integration"])
node(720, AY + 50, 190, 64, "Amazon SQS", "orders-events + DLQ", C["integration"])
node(960, AY + 50, 220, 64, "AWS Lambda workers", "email · invoice PDF · webhooks", C["compute"])
node(1230, AY + 50, 200, 64, "EventBridge Scheduler", "reconciliation · cleanup", C["integration"])
node(1460, AY + 50, 200, 64, "AWS Lambda", "scheduled jobs", C["compute"])
arrow([(670, AY + 82), (720, AY + 82)], color=C["async"], dash="6 4", marker="async")
arrow([(910, AY + 82), (960, AY + 82)], color=C["async"], dash="6 4", marker="async")
arrow([(1430, AY + 82), (1460, AY + 82)], color=C["async"], dash="6 4", marker="async")
text(480, AY + 168, "Spiky, asynchronous, short-lived work: scales to zero, retries + DLQ built in, never slows the API.", size=12, fill=C["muted"])
text(480, AY + 188, "Workers and jobs reach PostgreSQL only through RDS Proxy (reserved concurrency caps DB pressure).", size=12, fill=C["muted"])

# ------------------------------------------------------------------ arrows: request path
arrow([(190, 140), (226, 140), (226, 199), (255, 199)], color=C["req"])
label(208, 132, "DNS", fill=C["req"], anchor="middle")
arrow([(110, 184), (110, 274), (255, 274)], color=C["req"], label="HTTPS", label_pos=(150, 266))
arrow([(415, 274), (438, 274), (438, 125), (VX + VW / 2 - 85, 125)], color=C["req"])
igw_cx = VX + VW / 2
arrow([(igw_cx, VY + 18), (igw_cx, alb_y)], color=C["req"])
for i in range(3):
    cx = col_x[i] + 60
    arrow([(cx, alb_y + 54), (cx, svc_y + 10)], color=C["req"])
    arrow([(cx, svc_y + 72), (cx, proxy_y)], color=C["req"])
arrow([(col_x[0] + 140, proxy_y + 46), (col_x[0] + 140, db_y)], color=C["req"])

# management / control-plane
arrow([(col_x[2] + 270, svc_y + 124), (1360, svc_y + 124), (1360, 532), (RX + 2, 532)], color=C["mgmtline"], dash="3 4", marker="mgmt")
node(250, 860, 185, 106, "Deploy into the account", "ECR push · terraform apply", C["devtools"], "ECS deploy + migration task")
arrow([(195, 913), (250, 913)], color=C["mgmtline"], dash="3 4", marker="mgmt")
arrow([(col_x[1] + 60, VY + VH), (col_x[1] + 60, AY + 22), (575, AY + 22), (575, AY + 50)], color=C["async"], dash="6 4", marker="async")
label(700, AY + 16, "order events (outbox)", fill=C["async"], anchor="middle", halo="#FFF6FA")

# legend
LX, LY = 30, 1060
add(f'<line x1="{LX}" y1="{LY}" x2="{LX + 40}" y2="{LY}" stroke="{C["req"]}" stroke-width="2.2" marker-end="url(#req)"/>')
text(LX + 48, LY + 4, "request path", size=11)
add(f'<line x1="{LX}" y1="{LY + 20}" x2="{LX + 40}" y2="{LY + 20}" stroke="{C["async"]}" stroke-width="2.2" stroke-dasharray="6 4" marker-end="url(#async)"/>')
text(LX + 48, LY + 24, "async / events", size=11)
add(f'<line x1="{LX}" y1="{LY + 40}" x2="{LX + 40}" y2="{LY + 40}" stroke="{C["mgmtline"]}" stroke-width="2.2" stroke-dasharray="3 4" marker-end="url(#mgmt)"/>')
text(LX + 48, LY + 44, "control plane / AWS APIs", size=11)

out.extend(late)
add("</svg>")
sys.stdout.write("\n".join(out))
