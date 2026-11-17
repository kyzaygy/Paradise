package rules

// DefaultName is the name of the built-in config.
const DefaultName = "Default"

// DefaultText is the built-in config: local networks direct, everything else through the proxy.
const DefaultText = `# Paradise config
# Sections: [General], [Rule], [Host]. Policies: PROXY, DIRECT, REJECT.
# Rules are checked top to bottom, the first match wins.

[General]
bypass-system = true
skip-proxy = 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 127.0.0.1, localhost, *.local, captive.apple.com
tun-excluded-routes = 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.168.0.0/16, 224.0.0.0/4, 255.255.255.255/32
dns-server = system
ipv6 = true

[Rule]
DOMAIN-SUFFIX,local,DIRECT
IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
# Examples:
# DOMAIN-SUFFIX,example.com,DIRECT
# DOMAIN-KEYWORD,ads,REJECT
# GEOIP,RU,DIRECT
# GEOSITE,category-ads-all,REJECT
# RULE-SET,https://example.com/list.list,PROXY
FINAL,PROXY

[Host]
# router.lan = 192.168.1.1
`
