# README for lorcan

This server uses the e1000e NIC, which is apparently a big ol' piece of junk.

I had to edit /etc/network/interfaces and add this post-up line for ethtool:

```
iface nic0 inet manual
        # Adding because of e1000e hardware unit hang error
        post-up /sbin/ethtool -K nic0 tso off gso off
```
