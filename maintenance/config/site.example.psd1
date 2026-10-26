@{
    SiteCode           = 'acme-bkk1'
    Role               = 'srv'
    MaintenanceAccount = 'vmsmaint'
    LanSubnets         = @('192.168.1.0/24')
    # example.com is a placeholder until the real Cloudflare zone is confirmed.
    CloudflareHostname = 'vms-acme-bkk1-srv.maint.example.com'
    # optional fallback; remove the line for Cloudflare-only
    TailscaleTag       = 'tag:vms-site'
    AuthorizedKeysFile = '..\keys\engineers.pub'
}
