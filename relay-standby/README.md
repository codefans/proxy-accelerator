# relay-standby · 备用中转（端口转发）

主中转 IP 被封是迟早的事。备机是一台不同商家/ASN 的便宜 VPS，只做 nftables DNAT 把用户流量转给主中转，不跑 sing-box、不存用户，坏了随时换。

```bash
# 备机上
PRIMARY=<主中转公网IP> bash relay-standby/install.sh
# 主中转上
pa nodes add-standby <备机公网IP>
```

之后每个用户的订阅里多出 `PH-宿舍·备` 和 `HK-中转·备` 四个节点，排在对应主节点后面；fallback 组按顺序探测，主 IP 不通时自动用备机，恢复后自动切回。

- 用户侧看到的协议、密钥、SNI 和主中转完全一样（Reality 握手在主中转完成，备机只是透传）
- 延迟多一跳备机→主中转，同区域（都在日本或都在香港）通常 < 5 ms
- 删除：`pa nodes del PH-宿舍·备`、`pa nodes del HK-中转·备`
- 订阅服务本身不经备机：它走 Cloudflare 橙云到主中转的 2053，和中转 IP 是否被封无关
