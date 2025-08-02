Thanks for confirming. I’ll now investigate the three possible automation options for triggering `sojuctl user create` from your Next.js backend:

1. Executing `sojuctl` inside the Soju Docker container via `docker exec` or mounting the binary into the backend container.
2. Communicating with Soju’s admin UNIX socket interface (e.g., writing raw IRC-style commands).
3. Enabling and using a TCP-based admin interface for Soju if available.

I’ll compare their feasibility, security, and compatibility with your Docker + Railway setup and recommend the cleanest, most robust approach. I’ll also outline how to implement the integration from Node.js using `child_process.exec` or relevant libraries.


# Rewriting Provision Endpoint to Use Soju Admin Commands

## Current Approach: Direct Database Insertion (Status Quo)

Currently, the `provisionIrcUserHandler` directly inserts/updates records in Soju’s Postgres database for the `User` and `Network` tables. This approach uses SQL (via `ircQuery`) to **upsert** a new user and associate it with a network (e.g., “commonground”) pointing to the IRC server (Ergo). While this method works (and avoids needing Soju’s CLI or API), it has some drawbacks:

* **Tight Coupling to Soju’s DB Schema:** Any changes in Soju’s database schema or password hashing mechanism could break this code. For example, if Soju updates how it stores users or networks, the direct SQL might become incompatible. Using official admin commands would shield you from such internal changes.
* **Bypassing Business Logic:** Direct insertion means Soju isn’t “aware” of the new user until it queries the database. Normally, Soju’s built-in commands would handle hashing the password, user limits, etc. (In your code, you manually hash the password with `hashIrcPassword` before the insert.)
* **Maintenance Overhead:** You must ensure your SQL stays in sync with Soju’s expectations (e.g., ensuring the default values and flags like `admin` or `enabled` are set correctly). Currently you set `admin=false` and `enabled=true` explicitly. If Soju adds more fields or logic (like audit logging on user creation), direct DB writing would miss that.

**When is this acceptable?** Direct DB access might be acceptable in a controlled environment if you’re confident the schema is stable. It avoids needing additional tools. However, it’s generally not recommended because it circumvents the official interface. Using Soju’s admin commands is the safer, more **supported** approach for creating users.

## Option 1: Continue Using Direct DB Inserts (Not Recommended)

If you were to continue this way, you’d keep the existing logic: generate a username and secure password, hash it, and insert into the “User” table, then insert/update the “Network” entry. You’ve already handled conflicts (to avoid duplicate usernames) and provided meaningful error messages. Just be aware of the drawbacks above. In particular, ensure that the hashing algorithm (`hashIrcPassword`) matches Soju’s expectations (Soju uses bcrypt by default for passwords). Also, concurrency should be handled (your use of `ON CONFLICT` helps avoid race conditions when two requests try to provision the same user). This approach will work as long as Soju’s schema and behavior remain the same, but **proceed with caution** and thorough testing.

*(That said, let’s explore using Soju’s admin commands, which is the more robust path.)*

## Option 2: Using Soju’s CLI (`sojuctl`) via Child Process (Recommended)

Soju provides an admin CLI called **`sojuctl`** for managing a running bouncer instance. This CLI sends commands to Soju’s internal **BouncerServ** admin interface. We can leverage `sojuctl` to create users and networks, instead of writing directly to the database.

**How it works:** Soju must be configured to listen for admin commands on a Unix domain socket (by default, `/run/soju/admin`). The Soju config line `listen unix+admin://` enables this socket. The `sojuctl` tool, when run on the same host (or anywhere with access to that socket), will connect to this admin socket and send the requested command (like `user create`). Because this socket is a privileged control channel, it **“must not be exposed outside the container”** (for security). Instead, you share it internally.

**Setup needed:**

* **Soju Config:** Ensure the Soju container’s config includes the admin socket. For example, in `config.ini` add a line:

  ```ini
  listen unix+admin://
  ```

  This will create the default admin socket (e.g., at `/run/soju/admin`). In a Docker setup, this socket will appear inside the Soju container’s filesystem. You might choose to specify a custom path, like `listen unix+admin:///var/lib/soju/admin.sock`, if that fits better with volume mounts.

* **Accessible Socket:** Make the admin socket accessible to your Next.js backend container. There are a couple of ways:

  * **Shared Volume:** Mount a **shared volume** for the socket file. For example, in Docker Compose you could mount a volume at `/run/soju` for both the Soju service and the Next.js service. This way, when Soju creates `/run/soju/admin` (the Unix socket), the Next.js container can access the same file. Ensure file permissions allow the Next.js process to write to the socket. (Often the socket is owned by the Soju process user; if your Next.js runs as root, it can usually access it. Otherwise, you might adjust permissions or group ownership as needed.)
  * **Install Sojuctl in Soju container and Exec into it:** This is another approach: instead of sharing the socket, you could execute `sojuctl` *inside* the Soju container from the Next.js container. For example, by invoking `docker exec`. However, this requires Docker access from within the Next.js container (mounting the Docker socket or similar), which complicates things, especially on Railway. It’s typically easier to share the socket and run `sojuctl` directly in the Next.js container. (On Railway, direct Docker control from one container to another is usually not possible, so the shared socket approach is preferable.)

* **Sojuctl Binary in Next.js Container:** You will need the `sojuctl` command available in the Next.js backend container. There are a few ways to get this:

  * **Install via package:** If your container is Debian/Ubuntu based, check if Soju is available via apt (it might not be in all distros). On Alpine (if using an Alpine Node image), the package **`soju-utils`** provides `sojuctl` (and the soju server). For example, `apk add soju-utils` could install `sojuctl` and related tools.
  * **Copy from Soju build:** If you built Soju from source for the bouncer container, you could do a similar build or copy the binary. The Soju project builds three binaries (`soju`, `sojudb`, and `sojuctl`). You can compile these in a multi-stage Docker build and copy `sojuctl` into the Next.js image. (The blog example shows copying `sojuctl` into an Alpine image.)
  * **Use a pre-built binary:** If available, you could download a `sojuctl` binary release for your platform. As of now, Soju primarily distributes source, so compiling or using a package is more common.

* **Soju Config in Next.js Container:** The `sojuctl` tool needs to know how to connect to Soju’s admin socket. By default, it will look for the Soju config file (usually `/etc/soju/config`) to find the admin socket path. You have two sub-options:

  * **Provide Config to Sojuctl:** Mount the same Soju config file into the Next container (perhaps read-only). Then run `sojuctl -config /etc/soju/config ...` so that it reads the admin socket location. This is straightforward if you can share the config file.
  * **Point Sojuctl directly to socket:** Unfortunately, `sojuctl` doesn’t have a direct flag like `-socket <path>`; it relies on the config or the default path. If you used the default path and the file exists at `/run/soju/admin` in the Next container via the volume, `sojuctl` may find it as default **if** it knows to use it. The safer bet is to use the config. Alternatively, you could create a minimal config just for Next.js that contains only the `listen unix+admin:///...` directive (and perhaps dummy values for other required fields) and point `sojuctl` to that.

**Implementing in code:** Once the above setup is in place, your Next.js API route can invoke `sojuctl` commands via Node’s `child_process` (e.g., `exec` or `spawn`).

1. **Generate** the `ircUsername` and a secure `ircPassword` as you do now. (No need to hash the password yourself – the `sojuctl user create` will handle storing it securely in Soju’s DB.)
2. **Run** the Soju CLI to create the user. For example, the command would be:

   ```bash
   sojuctl user create -username "<ircUsername>" -password "<ircPassword>" -nick "<nickname>" -realname "<realname>"
   ```

   This corresponds to the Soju `user create` command (only admin can run this). You can omit `-admin` (it defaults to false, as you want regular users) and `-enabled` (defaults to true). Use the user’s display name for nick/realname (or the `ircUsername` as a fallback, similar to your current code).

   In Node, you might do something like:

   ```js
   const { exec } = require('child_process');
   const createCmd = `sojuctl user create -username ${ircUsername} -password ${ircPassword}`
       + ` -nick "${nickname}" -realname "${realname}"`;
   exec(createCmd, (err, stdout, stderr) => { ... });
   ```

   You’ll want to handle errors: if `err` is set or `stderr` contains an error message, log it and return a 500 response. On success, proceed to the next step.
3. **Add the network for the user:** After creating the user, you need to configure their network (soju does not automatically add a non-hostname “commonground” network by itself). You can achieve this via the `user run` command (which executes a sub-command as that new user). The CLI for adding the network would be:

   ```bash
   sojuctl user run "<ircUsername>" network create -addr "irc+insecure://ergo:6667" \
       -name commonground -username "<ircUsername>" -nick "<initialNick>"
   ```

   Let’s break this down:

   * `sojuctl user run "<ircUsername>" ...` tells Soju that the following command should be executed as that user (only an admin can do this).
   * `network create -addr irc+insecure://ergo:6667` is the command to add a new network pointing to your IRC server (Ergo in this case).
   * `-name commonground` assigns a short name “commonground” for this network. This is what users will use as `<username>/commonground` in their IRC client (or what The Lounge will use) to select the network.
   * `-username <ircUsername>` sets the IRC login username (ident) for the upstream connection. By default, if not provided, Soju would use the nickname as ident, but you likely want the ident to match the bouncer username (which you were doing in the DB insert).
   * `-nick <initialNick>` sets the IRC nickname for that network on connect. By default, Soju would use the account’s username as nick if not given. You might prefer the user’s display name here if it’s different or to preserve case, etc. (This was set in your SQL as the `Network.nick` field.)
   * (You can also include `-realname "<realname>"` if you want a real name per network, but it will default to the account realname if not set.)
   * No need to specify `-enabled true` since networks default to enabled.

   This command will cause Soju to create the network entry in its DB and immediately attempt to connect to `ergo:6667` on behalf of the user. If Ergo is online, the bouncer may start the IRC connection right away. If that’s not desired (perhaps you want to defer connecting until the user actually opens The Lounge), you could add `-enabled false` to the network creation to prevent auto-connecting. However, since your original code set networks as enabled, it’s fine to let it connect immediately so that backlog starts accumulating.

   In Node, run this with `exec` after the user creation succeeds:

   ```js
   const networkCmd = `sojuctl user run ${ircUsername} network create -addr "irc+insecure://ergo:6667"` + 
                      ` -name commonground -username ${ircUsername} -nick "${nickname}"`;
   // ...exec networkCmd similarly...
   ```

   Again, handle any errors (`stderr`) and log output.
4. **Return Result:** If both commands succeed, you can respond with the JSON containing `success: true`, along with the `ircUsername`, the **plain `ircPassword`**, and `networkName: "commonground"`, just like you intended. (The Lounge or client will need the plain password to log in, since it’s stored hashed in the DB.)

**Pros of this approach:**

* You’re using Soju’s supported admin interface. This means Soju itself will hash the password and create the DB entries (fewer chances for error). It’s the same as an admin running the commands manually, which is an officially supported way to provision users.
* Errors from Soju (e.g., “username already exists”) will come through `sojuctl` and you can catch them. The CLI’s exit code and stderr will indicate if something failed (for example, if the user exists, it should fail; you can then decide to update instead via a different command, or just report an error).
* No need to maintain SQL queries for Soju’s schema. If Soju changes how it stores users, as long as you have a compatible `sojuctl`, it will handle it.
* Security: The admin socket is not exposed externally – you’re only using it internally. This means only your backend (which you control) can issue admin commands, not arbitrary network requests. This is an improvement over, say, exposing an HTTP endpoint in Soju for user creation (which doesn’t exist by default).

**Cons / Considerations:**

* **Setup complexity:** You must ensure the `sojuctl` binary is present and the containers share the admin socket. This is extra DevOps work (updating Dockerfiles, Compose, etc.). On Railway, you’ll need to configure volumes or shared filesystem between the Soju and Next.js containers (Railway supports persistent volumes which you could potentially share, or use a temporary in-memory volume for the socket). If volume sharing on Railway is not straightforward, you might instead run both Soju and Next.js in a single container (not ideal) or fall back to Option 3 below.
* **Error handling:** `child_process.exec` has a max buffer for stdout/err. The output from these commands is tiny, so that’s fine. But you should still handle cases where the exec itself fails to spawn. Also, consider what to do if user already exists – currently your DB approach would update the existing user’s password and network. With `sojuctl`, running `user create` on an existing username will error. You could catch that and then perhaps run `sojuctl user update` (for password) or just treat it as an error (since conflict likely shouldn’t happen often unless someone tries twice).
* **Performance:** Spawning a process for each provision request is slightly heavier than a DB query. However, this is usually negligible (creating a user is a rare operation and sojuctl’s work is minimal). Just ensure you don’t spawn a bunch in parallel that overload the container. A small pool or queue might be useful if you expect bursts of sign-ups.
* **Security:** Keep the admin socket secure. Only the necessary containers should have access. Also, ensure the generated password is handled carefully (not logged in plaintext except where needed). Your code logs a success message with `ircPassword` currently – be mindful of that in production logs.

## Option 3: Using IRC (BouncerServ) Commands Programmatically

A third approach is to interact with Soju **as an IRC client**, using an admin account to issue commands via the `BouncerServ` interface. Essentially, Soju’s admin commands can be executed by an admin user from any IRC client connected to the bouncer (they are the same commands). For example, an admin user can send a private message to the service (often “BouncerServ”) like:

```
/msg BouncerServ user create -username bob -password secret ...
```

Soju will interpret that and create a new user (if the sender is an admin). Similarly, you could then `/msg BouncerServ user run bob network create ...` for the network. This is exactly what `sojuctl` is doing under the hood (but via the Unix socket).

To automate this, your Next.js backend could act as an IRC client:

* Use an IRC library (Node has several, like [irc-framework](https://www.npmjs.com/package/irc-framework) or [node-irc](https://www.npmjs.com/package/irc)) or even raw sockets, to connect to the **Soju bouncer** service on its IRC port (e.g., `soju:6667` on the Docker network).
* Authenticate as an existing **admin user** on the bouncer. (You would need to have created an admin user beforehand – perhaps manually or using `sojuctl` once. Often, the first user in Soju is an admin by design. If not, you’ll need to ensure an admin exists to use this method.)
* Once connected (as if you were a client), programmatically send the same commands: e.g., send the PRIVMSG or NOTICE to BouncerServ with the text `user create ...`. You might have to listen for a response or success message (BouncerServ typically replies with either a confirmation or an error message in that service query buffer).
* After issuing the commands and getting confirmation, you can close that IRC connection (or reuse it for multiple provisions if keeping a persistent admin bot).

**Pros:**

* Doesn’t require sharing the admin socket or installing `sojuctl`. It uses the existing IRC interface on port 6667 (or 6697 if TLS). Since your Next.js container can reach the Soju container over the Docker network (e.g., `soju:6667`), it can open a socket to it just like The Lounge would.
* Uses Soju’s public protocol (IRC + the BouncerServ commands) – no direct DB writes.

**Cons:**

* **Complexity:** You need to implement an IRC client or use a library, handle asynchronous messaging, and parse responses. Essentially, you’re writing a small IRC bot to provision users. This is more complex than a simple `exec` call.
* **State:** You must manage the admin connection. For example, on Railway your Next.js may scale or restart – maintaining a persistent IRC connection might be tricky. You could alternatively connect, run commands, and disconnect for each provision request (which is doable but adds overhead).
* **Timing issues:** If you disconnect immediately after sending the command, you might miss error replies. It’s important to wait for a success/failure response from BouncerServ before quitting. This means writing code to listen on the socket for the server’s NOTICE or message saying “User X created” or such, which the manual implies exist.
* **Admin availability:** This approach hinges on having an admin user’s credentials. You’ll have to store that admin username & password in your backend config to authenticate the IRC session. That is an additional secret to manage. With the direct `sojuctl` method (Option 2), you don’t need an admin username/password – access to the socket is the authority.

**When to use:** If you absolutely cannot use `sojuctl` (say, you can’t easily install it or share the socket in your deployment environment), this method can work. It’s essentially using the bouncer’s own protocol to configure itself. Some have used this approach to build web interfaces for ZNC or Soju by scripting the IRC protocol. But given that you’re open to using `child_process.exec` and have control over the environment, Option 2 is typically simpler and more robust.

## Conclusion and Recommendation

All three approaches will achieve the goal of provisioning a new Soju (IRC bouncer) user and their network:

* **Direct DB (current)** – Works now, but fragile long-term and bypasses official methods.
* **Sojuctl CLI (recommended)** – Uses Soju’s supported admin interface via the Unix socket. This is cleaner and safer, albeit requiring some setup to enable and integrate the CLI. It aligns with how Soju’s maintainers expect admins to automate tasks (indeed, the first user creation is typically done with `sojuctl` in container deployments). Given that you responded positively to using `child_process.exec`, this seems like the best path.
* **IRC/BouncerServ automation** – An alternative if socket or CLI usage is not feasible. It can be made to work but introduces more moving parts in your code.

**My strong recommendation** is to implement Option 2 (Sojuctl via child process). It strikes a good balance: using officially supported commands and keeping your backend code relatively straightforward. The additional DevOps effort (ensuring the CLI and socket access) is one-time and will pay off in reliability. By using `sojuctl`, any changes in Soju’s internals (like password hashing) won’t require changes on your side – you’re delegating that work to Soju itself.

Finally, remember to test thoroughly in both your dev (Docker) and prod (Railway) environments. On a local Docker network, for example, you might test by exec-ing into the Next.js container and running the `sojuctl` commands manually to ensure the socket connection works. On Railway, confirm that the volume sharing for the socket is functioning and that the `sojuctl` binary can run. With those in place, your Next.js `POST /provisionIrcUser` endpoint should be able to create users on the fly using Soju’s admin commands reliably. Good luck!

**Sources:**

* Soju Manual – *Admin interface and user creation commands*
* Soju Manual – *Network creation command and options*
* Henrique Dias’ IRC Bouncer Docker Guide – *Soju config for admin socket & usage of sojuctl*
