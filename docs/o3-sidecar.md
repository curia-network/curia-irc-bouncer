Thanks for the clear technical context. I’ll now investigate whether Soju v0.8.0 supports a TCP-based admin interface, including:

* Validity of `admin://` or similar TCP-based admin `listen` directives
* Existence and usage of an `admin-password` directive
* Supported admin protocols in Soju v0.8.0 and any changes in newer versions
* Recommended strategies for cloud-based programmatic administration (e.g., HTTP bridge via sidecar container)

I’ll confirm this via both Soju documentation and the v0.8.0 source code, and I’ll recommend the cleanest and most secure path forward for production environments like Railway.


# Soju IRC Bouncer Remote Admin Interface: Capabilities and Solutions

## Network-Based Admin Interface (Question A)

**Soju does not support any TCP/IP or network-based admin interface in current versions.** The only supported administrative interface is via a Unix domain socket (the `unix+admin://` listener) for local control. In other words, Soju’s configuration does **not** allow a `listen admin://0.0.0.0:<port>` style directive – such a directive is not recognized by Soju’s parser. The error `"unknown directive 'admin-password'"` encountered confirms that these config options are invalid in Soju. Official documentation lists all valid `listen` URIs (TLS IRC, plaintext IRC, WebSocket, ident, Prometheus, etc.) and includes **only** `unix+admin://[path]` for admin control (which creates a local socket for `sojuctl`). No variant of an `admin://` scheme over TCP is mentioned, indicating there is no built-in network admin port.

This design is intentional for security – Soju’s admin control is meant to be local-only. The `sojuctl` tool uses the Unix socket to send admin commands internally, preventing external clients from connecting to an admin port. The Soju source code explicitly ensures that regular IRC clients cannot accidentally connect to the admin socket, reinforcing that admin access must remain on the local Unix domain socket (and thus accessible only with appropriate OS permissions).

## `'admin-password'` Configuration Directive (Question B)

There is **no** `admin-password` (or similar) directive in any official Soju version up to and including the latest releases. The Soju configuration file supports directives like `listen`, `tls`, `hostname`, `db`, etc., but nowhere in the documentation or code is there an `admin-password` setting. The attempt to use `admin-password` in the config resulted in an “unknown directive” error because Soju simply doesn’t have this concept in its config.

**How Soju handles admin authentication:** Instead of a global admin password, Soju uses per-user accounts and an internal flag to mark admins. You create an admin user (or upgrade a user to admin) via the **normal user management commands** – for example, using `sojuctl` or BouncerServ commands to create a user with the `-admin true` flag. Each user (including admins) has their own login password set at creation time. Thus, *admin credentials are just a user’s username/password who has admin privileges*, not a separate global admin interface password. There is no configuration directive to set an admin password because authentication is handled at the user account level (with internal auth or potentially an external auth provider, if configured). In summary, no released Soju version recognizes `admin-password` in the config – the only way to control admin access is by creating an admin user account with its own password.

## Official Remote Administration Methods (Question C)

**Soju’s officially supported admin mechanisms are:**

* **Local Unix Socket + sojuctl:** By running `sojuctl` on the same host (or within the same container) as Soju, you can send administrative commands to the bouncer. This requires the Soju config to include a `listen unix+admin://…` socket (default path `/run/soju/admin`) and the operator to have filesystem access to that socket. In traditional setups, an admin would SSH into the server or use a local terminal to run `sojuctl` commands. In a Docker context, this is why you were using `docker exec ... sojuctl ...` – to execute the admin tool inside the container where the socket is available.

* **BouncerServ in-band IRC commands:** Soju exposes an IRC service named **BouncerServ** for management. An administrator who is connected to the bouncer as an IRC client can send management commands via PM to `BouncerServ` (or via special `/msg $*` or `/notice` commands). For example, an admin user can create new users or networks by issuing `/msg BouncerServ user create <username> -password <pass>` in their IRC client. This has the same effect as using sojuctl, but it’s done through the IRC protocol as an authorized admin user. The official docs note that any command available in sojuctl can be executed as an IRC message to BouncerServ when you’re logged in as an admin. Essentially, admin users can manage the bouncer “remotely” by just connecting to it like a normal user (over TLS or local host) and using the admin commands in-band.

**Recommended approach for remote administration:** Since there is no dedicated remote admin socket, the Soju developers expect you to use one of the above methods. In practice, if you need to administer Soju from afar, you would either remotely access the host (to run sojuctl on the Unix socket) or connect an IRC client as an admin user and perform tasks through BouncerServ. The **official stance** is to keep the admin interface local; Soju does **not** provide a built-in HTTP API or direct TCP admin port for security reasons. This means the onus is on operators to create a safe way to trigger `sojuctl` or BouncerServ commands when not on the same machine.

## Version and Build Considerations (Question D)

You are using Soju **v0.8.0**, and according to our research no newer version in the 0.8.x series or the latest 0.9.x has added a TCP admin interface. We found **no evidence of any hidden build flags or optional compilation features** that would enable a networked admin socket – such a feature would be prominent in release notes or documentation, and none is mentioned. The latest documentation (for Soju 0.9.0 as packaged on Arch Linux) still shows only the Unix admin socket option for admin access. Likewise, there is no `admin-password` directive in 0.9.0 either.

In short, you are **not missing any configuration or build option** – the capability simply doesn’t exist in the official Soju codebase as of now. If a TCP admin interface were ever added in a future release, it would come with appropriate config directives and documentation (for example, one might expect an `admin-listen` directive or similar), but our search through Soju’s repository and change logs did not find any such addition. All signs indicate that remote admin over TCP is deliberately not implemented.

*(For completeness: some package maintainers (e.g. NixOS) have service wrappers that enable the Unix admin socket by default or provide a helper for sojuctl, but these do not introduce new network interfaces – they only simplify using the existing Unix socket.)*

## Solutions for Remote Administration in Container Environments

Given the above limitations, **how can one safely administer Soju on a cloud platform like Railway, where direct shell access or Unix sockets are not readily accessible from outside?** Here are a couple of approaches to consider:

* **Sidecar Container or Internal API Service:** This is a practical and secure workaround. You can run a small sidecar service within the same Railway deployment that has access to Soju’s Unix socket (for example, by sharing a volume or mounting the `/run/soju/admin` path into the sidecar). This sidecar could expose an HTTP(S) endpoint or RPC interface which your Next.js backend calls. Under the hood, the sidecar service would invoke `sojuctl` (or even link against a library or use the socket protocol directly) to execute the needed admin commands. For instance, a simple Node, Go, or Python service can listen for REST calls (like “create user X with password Y”) and then run the equivalent `sojuctl user create -username X -password Y` on the Unix socket. Because the sidecar runs in the same environment as Soju, it can communicate with the admin socket locally. **Important:** You should secure this sidecar API (e.g. with a strong auth token or network restrictions) since it has privileged control over the bouncer. This approach essentially replicates what “docker exec sojuctl” did, but in a cloud-friendly manner – your Next.js app calls the sidecar’s API, and the sidecar performs the admin action on Soju. This pattern is commonly used to bridge container-only interfaces to the outside world in a controlled way.

* **IRC Admin Automation:** Since Soju already accepts admin commands via IRC, another approach is to have your backend act as an IRC client to Soju. Your Next.js backend (or a separate worker service) could programmatically connect to the Soju bouncer’s normal IRC port using the credentials of a pre-created admin user. Once connected (just as if it were a client), it can send the same BouncerServ commands (e.g., send a private message to BouncerServ with `user create` or `network add` instructions). After performing the task, it can disconnect. This avoids any special sidecar, but does require implementing an IRC client or using an IRC library in your backend. It’s a bit more involved in terms of protocol handling, but it leverages Soju’s in-built remote admin via IRC. The upside is that this connection is over TLS (if you use the ircs port) and uses Soju’s authentication, so it’s secure as long as your admin user’s credentials are kept safe. Essentially, your backend becomes an automated IRC admin bot. This method is less direct than using sojuctl, but it’s fully supported by Soju’s design (it’s equivalent to a human admin using an IRC client).

* **SSH or Exec Workarounds:** If Railway or your environment provided some way to run commands inside the container (for example, via a web console or an SSH session into the container), one could use that to run sojuctl. However, on platforms like Railway such options are often limited or not intended for regular use. Since you explicitly noted docker exec isn’t available in production, this isn’t a viable routine solution, but it’s worth mentioning that some platforms allow one-off exec into the container for maintenance. This would be more of a manual fallback than a scalable solution.

Given your use case (automated provisioning of users/networks from a Next.js API), the **sidecar HTTP bridge approach** is likely the cleanest solution. It allows your backend to hit a straightforward HTTP endpoint (internal to your infrastructure) whenever a user needs to be provisioned, and the sidecar will translate that to the appropriate sojuctl commands on the Unix socket. This approach has been successfully used in similar scenarios when software only exposes a Unix socket for control. Just ensure the sidecar is well-secured (since it has broad powers over Soju, you might even restrict it to an internal network or require an auth secret that your Next.js knows).

## Summary of Answers

* **A) Network-based admin interface:** No, Soju does not support a TCP or remote admin listener. Only a Unix-domain admin socket (`unix+admin://`) is available for administrative control.
* **B) `admin-password` directive:** No, there is no such directive in any Soju version. Soju’s config has no concept of a global admin password – admin users are managed through the user system (create an admin user with its own password).
* **C) Official remote admin method:** The officially intended methods are using the local Unix socket with `sojuctl` or using an admin user to send commands via IRC (BouncerServ). In practice, this means you must have some access to the host or be logged in as an admin through an IRC client to administer Soju. There is no built-in web or TCP admin API.
* **D) Missing version or flag:** You are not missing anything – as of v0.8.0 (and even in 0.9.0), no option exists to enable a TCP admin interface. There is no build flag to turn it on. The feature simply isn’t present in upstream Soju, so your configuration attempt failed not due to your version, but because the feature doesn’t exist in any released version.

**References:**

* Soju official manual (soju(1)) – supported listen URIs (shows only `unix+admin://` for admin socket)
* Sojuctl manual – requires `unix+admin://` socket and local permissions (no mention of any network mode)
* Soju usage guide (Comfy.Guide) – demonstrates using `unix+admin://` for sojuctl and using BouncerServ for user creation
* Soju documentation – user creation command with `-admin` flag (admin user setup)
