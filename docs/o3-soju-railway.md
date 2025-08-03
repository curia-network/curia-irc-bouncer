Great, I’ll now investigate the most robust and maintainable solution for your Soju IRC Bouncer deployment on Railway. I’ll focus on how to implement Option 2 — embedding the HTTP sidecar inside the Soju container — and compare it with best practices and patterns used by other IRC bouncer deployments.

I’ll also evaluate multi-process container strategies (entrypoint.sh, supervisord, PM2), limitations of Railway’s container architecture, and whether there are any production-tested techniques specific to Railway for shared socket access or inter-process communication.

I’ll report back shortly with recommended implementation patterns and tradeoffs.


# Railway Deployment Architecture Research: Soju IRC Bouncer Admin Interface Challenge

## Background and Problem Context

Deploying a **Soju IRC bouncer** with a custom admin interface on Railway (a cloud PaaS) presents unique challenges due to platform constraints. Locally, our Docker Compose setup consists of three components working in tandem:

* **Soju IRC Bouncer** (v0.8.0) – runs as a daemon with a PostgreSQL backend. It exposes an admin interface via a Unix domain socket (`unix+admin://` at `/var/lib/soju/admin.sock`).
* **Sidecar Admin Service** – a Node.js/Express service that bridges HTTP calls to Soju’s admin interface. Locally it shares a volume with Soju to access the Unix socket and uses `docker exec` to run Soju’s CLI (`sojuctl`) inside the Soju container.
* **Main Application** (Next.js) – calls the sidecar’s HTTP API to provision IRC users (create users, update passwords, create networks, etc.).

**Local Workflow:** This architecture works on Docker Compose because it relies on features like shared volumes and Docker’s exec capabilities:

1. Soju creates a Unix admin socket at `/var/lib/soju/admin.sock`.
2. The sidecar service has the same volume mounted, so it can access the socket file.
3. The sidecar executes `docker exec curia-irc-soju sojuctl ...` commands inside the Soju container via Node’s `child_process.exec()`.
4. The main app triggers sidecar endpoints, which in turn invoke `sojuctl` commands to create users, set passwords, and configure networks. This uses Soju’s **official admin interface** at runtime (through the socket) and works flawlessly in dev.

**The Challenge:** Railway’s deployment model doesn’t support this arrangement out-of-the-box. Railway runs each service in an **isolated container** environment with strict limitations:

* **No shared volumes or filesystem** between services (each service’s container has its own file system). This means the sidecar cannot mount `/var/lib/soju` from the Soju service as it did locally.
* **No Docker daemon** in the containers – thus no `docker exec` or Docker Compose linking. We cannot spawn processes inside one container from another, as was done with `docker exec`.
* **Isolated networking only:** Services can only communicate over network requests. There is no Unix domain socket sharing across services, and no built-in concept of Kubernetes-like sidecars or pods.
* **Single process entrypoint per service:** Railway expects one primary process (though we can spawn sub-processes manually, see below). We cannot simply deploy a multi-container pod; each service is deployed separately unless we combine them.

Given these constraints, the current approach fails on Railway – the sidecar cannot reach the Soju admin socket or invoke `sojuctl`. Indeed, in our tests the sidecar saw no connection attempts (since the socket wasn’t accessible), and no user provisioning calls succeeded.

## Why Soju’s Admin Interface is Hard to Expose on Railway

Soju’s admin interface is intentionally designed as a **Unix domain socket** (not a network port) for security. The documentation emphasizes that the admin socket “**will only be used for some administrative commands and must not be exposed outside the container**”. There is *no built-in HTTP or TCP admin port* for Soju (as of v0.8.0), and the CLI `sojuctl` expects filesystem access to that socket.

In practice, Soju provides two ways to perform admin tasks:

* **Using `sojuctl`:** the official CLI tool communicates via the Unix socket to run commands (e.g. create user, delete user, etc.). This requires being on the same host/container as Soju or having the socket accessible.
* **Using IRC “BouncerServ” commands:** If an admin user is logged in to the bouncer, they can send IRC messages to a service called `BouncerServ` to manage users and networks (this is what sojuctl effectively does under the hood). For example, an admin can `/msg BouncerServ user create <user> -password <pass>` to create a user.

Direct database manipulation (in PostgreSQL) is **not the intended method** to manage Soju users at runtime. While one could insert a new user row or change a password in the database, Soju would not immediately become aware of those changes without a restart. In fact, Soju’s manual notes that certain config options like `db` and user definitions cannot be reloaded on the fly – the bouncer doesn’t dynamically pick up new users from the DB while running. This means provisioning users purely via SQL would **require restarting Soju** to load the new data, which is impractical for real-time user creation.

**In summary:** Railway’s environment prevents the sidecar from using the Unix socket or `docker exec` approach, and Soju has no HTTP API to call as an alternative. We need a deployment architecture that **respects Railway’s one-container-per-service model** while still leveraging Soju’s admin interface for instant user provisioning.

## Evaluating Deployment Options

We’ve identified three possible approaches to solve this:

### Option 1: **Direct Database Access (Avoid Soju Admin Interface)**

**Idea:** Bypass Soju’s socket and have the main app or sidecar directly manipulate the PostgreSQL database to create users and networks. For example, inserting a new user into Soju’s `users` table and hashing a password, etc. This would then require triggering Soju to recognize the new user.

**Pros:**

* Simpler on the surface – no need for a special admin socket or sidecar communication. The main app could call an internal API or use an ORM/SQL to add users.
* Could work within Railway’s constraints since the main app can reach the database (Railway Postgres plugin or external DB) and no inter-container socket is needed.

**Cons:**

* **Soju won’t see changes until restart:** As noted, Soju doesn’t automatically load new users from the DB while running. You would likely have to restart the Soju service container each time a user is added or updated. Restarting for every user signup is obviously untenable for a production service (downtime and overhead).
* **Bypassing official interfaces:** This approach goes against Soju’s design. The admin socket and BouncerServ exist to safely handle runtime changes. Writing directly to the DB could miss internal steps (e.g. hashing, default network creation, etc.) or lead to inconsistencies unless we duplicate Soju’s logic.
* **No immediate feedback:** Even if we did manipulate the DB, we’d need a mechanism to tell Soju to reload or the new user to log in. There’s no built-in signal for “reload users” (HUP doesn’t reload `db` or `listen` sections).
* **Security and maintainability:** We would be effectively reverse-engineering Soju’s database schema and logic. Any Soju update could break our direct DB method, whereas using `sojuctl` (option 2) keeps us aligned with official support.

Given these issues, **Option 1 is not robust**. It’s a last resort if we absolutely cannot use the admin socket. It sacrifices the real-time nature (since we’d require restarts or heavy workarounds) and is not recommended for maintainability. In production IRC bouncer setups (e.g. ZNC or Soju), administrators typically use provided admin commands or web UIs rather than directly editing the database, precisely to avoid these problems.

### Option 2: **Embed the Sidecar Logic into the Soju Container (Single Container)**

**Idea:** Run Soju and the HTTP sidecar **in the same Railway service** (one container), so that they can communicate via the Unix socket internally. This effectively recreates the local setup but within a single container boundary. There are a few ways to implement this, such as:

* Merging the Dockerfile for Soju and the sidecar, so that one image contains both the Soju binary and the Node.js app.
* Using a custom entrypoint script or process manager to launch both the Soju daemon and the Node/Express server in one container.

In this setup, no external volume is needed – the Unix socket file is simply present on the container’s filesystem and both processes can access it locally. The sidecar can invoke `sojuctl` directly (since `sojuctl` could be included in the image along with Soju) or even call Soju’s internal API via the socket file path.

**Pros:**

* **Preserves Soju’s intended usage:** We continue using `sojuctl` and the admin socket for user management, which means new users/networks are applied immediately with no restart. This is exactly how Soju is meant to be managed at runtime.
* **No architectural hacks:** We don’t expose the admin interface over the network (avoiding security risks) – the socket remains internal to the container. This aligns with best practices (admin socket “must not be exposed outside”).
* **Single service on Railway:** From Railway’s perspective, we deploy one service container. This avoids complex network calls between services and simplifies environment management (only one service to configure, one set of env variables, etc.).
* **Works in dev and prod:** We can maintain the local Docker Compose for development if desired, or also test the combined container locally. The combined container approach can be used on Railway without special platform features. It’s essentially running a mini “supervisor” that starts two processes.
* **Performance:** The overhead of running both processes in one container is minimal. Soju is lightweight (written in Go), and the Node sidecar is only active during provisioning calls. Communication between them (via `sojuctl` and a Unix socket) is very fast – likely faster than the original `docker exec` approach, since we no longer spawn a Docker command or cross-container call. Provisioning should still happen in sub-second timeframes.

**Cons / Considerations:**

* **Container complexity:** Running multiple processes in one container breaks the typical “one process per container” principle. We need to ensure both Soju and the sidecar start properly and manage their lifecycles. If one process crashes, it should ideally bring down the container or restart appropriately.
* **Process management:** We have to decide how to start and keep both processes running:

  * A simple **wrapper script** can start Soju in the background, start the Node server, then use shell `wait` to keep the container alive until one exits. (Docker’s documentation provides an example of this approach.) This is straightforward but we must handle signals correctly so that a `SIGTERM` (stop) from Railway will terminate both child processes.
  * Using a **process manager** like **supervisord** or **s6** is another approach. Supervisord can spawn both processes and restart them if they crash, and handle logging. Docker’s best practices note that this is more involved (you have to include supervisord in the image and add a config for it). For a relatively simple case (two processes), a full supervisor might be overkill, but it does add resilience.
  * Since our sidecar is Node.js, another idea is using Node’s clustering or a tool like PM2 to start Soju as a child process. However, this complicates signal handling and is not as clean as a shell script or supervisord. It’s generally better for the container’s PID 1 to be an init or supervisor process rather than a Node process managing an external Go process.
* **Resource sharing:** Both Soju and Node will share the container’s CPU/RAM. We need to ensure the container has enough memory for both (which it should in most cases – Soju’s footprint is small, and the sidecar only does occasional work). We should also be mindful of not running out of file descriptors if `sojuctl` is called very frequently, but that’s unlikely with typical user signup rates.
* **Port conflicts:** Now that one container runs two servers, we have multiple ports to expose: the Soju IRC ports (e.g. 6667/6697 for IRC and TLS, and maybe a WebSocket port) and the sidecar’s HTTP port. Railway typically maps one primary port for HTTP services. In our case, we may need to expose the sidecar’s HTTP port as the service’s primary port (so the main app can reach it), and also expose the IRC ports. Railway does allow exposing multiple ports if specified. We must configure the Dockerfile or Railway service settings to expose both the IRC port(s) and the sidecar HTTP port. The admin socket, however, remains internal and not exposed.

On balance, **Option 2 is the most robust and maintainable solution** given the constraints. It essentially replicates how one might run Soju and an admin API on a single VM: both processes side-by-side, communicating through a Unix socket. This keeps us in line with Soju’s supported admin mechanism and avoids any need to modify Soju itself or do unsupported hacks. Many production deployments of IRC bouncers use a similar pattern – for example, running ZNC with its built-in web admin in one process, or Soju with a local CLI tool. Here, our “web admin” for Soju is the sidecar, and we’ll run it in-process with Soju.

**Implementation Notes for Option 2:**

* We will create a unified Docker image. For instance, start from a base (perhaps Alpine Linux) and install/ADD Soju binaries (`soju` and `sojuctl`) as well as Node.js and our sidecar code. The Dockerfile from Henrique Dias’s tutorial builds Soju from source, but we could also use a pre-built binary or minimal image since we prefer not to build from source (as per your note).

  * One approach: Use a multi-stage build. Stage 1 could copy or download the `soju` and `sojuctl` binaries (for v0.8.0) onto an Alpine image. Stage 2 could be a Node image to build the sidecar. Then combine them – however, combining two base images is tricky. It may be easier to use an Alpine base, `apk add nodejs npm`, and also include the Soju binaries in the same image. This way we have both commands available.
* Use an **entrypoint script** (let’s call it `entrypoint.sh`) as the container’s startup command. This script might:

  1. Start the Soju service (e.g. `soju -config /etc/soju/soju.conf &` to background it).
  2. Possibly wait a second for the socket to be created (Soju should create the admin socket quickly, so this might not be necessary if the sidecar can handle a retry).
  3. Start the Node/Express sidecar (e.g. `node server.js` or `npm start`).
  4. Use `wait -n` to wait for either process to exit. If one of them stops (say Soju crashes or the Node process ends), `wait -n` will return and the script can exit, which will terminate the container. Railway can then restart it if you have a restart policy. This ensures we don’t have a “zombie” container with only one of the two running.
  5. (Optional) Handle termination signals: When Railway wants to stop the container (deploy update or scale down), it will send SIGTERM to the entrypoint process (our script). We might trap this signal in the script to gracefully shut down both Soju and Node. If not trapped, SIGTERM will by default propagate to child processes or eventually SIGKILL everything after a timeout. Using `--init` (tini) is recommended so that zombie processes are reaped and signals are handled correctly. We can add `ENTRYPOINT ["tini", "--"]` in Docker to ensure a minimal init.
* No **Docker exec** is needed anymore: the sidecar can directly run `sojuctl` commands by calling the binary. Since it’s the same container, `child_process.exec("sojuctl user create ...")` will work. We just have to make sure `sojuctl` knows the config path (or socket path). In our config, we’ll keep `listen unix+admin://` (which defaults to `/run/soju/admin` or similar). As long as `sojuctl` uses the same config file, it will find the socket. We might set an env var or use `-config /etc/soju/soju.conf` in the sojuctl command, just as we did with Docker exec.
* **Environment and Ports:** We should configure the sidecar to listen on a port (e.g. 3000 or whatever) and ensure Railway knows this is the web port (if the main app calls it over HTTP). We’ll mark that in the Railway service settings. The Soju IRC port (e.g. 6667/6697) can also be exposed. Railway allows multiple ports, but only one may get an automatic domain. Likely, the sidecar HTTP will be the one with a Railway URL, and the IRC port we might access via a **TCP** domain or configure a custom domain for IRC. (In the Henrique Dias setup, Caddy was used to provide TLS for IRC on port 6697; on Railway, we might not have a TCP load balancer for arbitrary ports, so we may need to consider that. If Railway doesn’t support exposing arbitrary TCP ports for IRC, a workaround is needed – possibly using a **TCP reverse proxy** container or enabling WebSocket and using an external proxy. This is somewhat outside the scope of the admin interface, but worth noting for production: Railway is HTTP-oriented, so serving an IRC port might require a proxy or using WebSockets on an HTTP port.)

Despite those details to iron out, **Option 2 is our preferred solution** because it **maintains a clean separation of concerns** (we still have a dedicated admin API process) while satisfying Railway’s one-container rule. It’s also a pattern seen in other deployments – for instance, some projects bundle an admin UI and the service in one container for simplicity on platforms that don’t support sidecars.

### Option 3: **Introduce a Network-based Admin Interface via Proxy**

**Idea:** Since Soju doesn’t natively offer a TCP or HTTP admin port, we could create one ourselves. This would mean **running an intermediary inside the Soju container** to forward admin commands to Soju’s Unix socket. Two sub-approaches:

* Run a tool like `socat` or `netcat` in the Soju container to listen on a TCP port and forward data to the Unix socket. For example, `socat TCP-LISTEN:12345,fork UNIX-CONNECT:/var/lib/soju/admin.sock`. The sidecar (in a separate container) could then connect over TCP to port 12345 to send commands.
* Extend Soju or write a small Go program to open an HTTP endpoint that internally uses the admin socket (essentially what our sidecar does, but running inside the Soju container). This is akin to building a mini-HTTP server around `sojuctl` and would also need to be inside the same container to reach the socket.

**Pros:**

* Keeps Soju and sidecar as separate services from Railway’s perspective, communicating over a network port. Each could scale or restart independently (though scaling Soju independently is not useful here).
* The main app would still talk to the sidecar over HTTP as before; the only difference is the sidecar would call the Soju admin over TCP instead of via `docker exec`.

**Cons:**

* **Security risk:** Exposing the admin interface over TCP, even internally, is dangerous. Soju’s admin socket has no authentication on its own (it relies on filesystem permissions). If we open it on TCP, *anyone who can reach that port* could potentially run admin commands. We could mitigate by binding the port to localhost and only allowing the sidecar’s container to connect, but in Railway, “localhost” in one service is not accessible from another. We’d have to bind to 0.0.0.0 but perhaps restrict by firewall (Railway might not provide internal firewalls). This goes directly against the recommendation *“must not be exposed outside”*.
* **Complex custom solution:** This approach adds another moving piece (socat or a custom proxy app). It’s more things to maintain and monitor. If the proxy fails, admin functionality breaks.
* **No official support:** Soju doesn’t support this out of the box, so we’re essentially hacking in a network interface. Future Soju versions might not consider this use-case.
* **Still requires combined deployment or extra container:** Notably, even with socat, you’d end up running socat *inside* the Soju container (to access the socket) – which is effectively also making the Soju container multi-process (Soju + socat). If you instead ran socat as a separate container, you’d need shared volume for the socket (back to square one – not possible on Railway).
* If we built a custom small HTTP server for admin, we would be duplicating what the sidecar does, but now tightly coupled to Soju’s container.

Given these drawbacks, Option 3 doesn’t seem as clean or maintainable. It’s theoretically possible (and might be a quick fix to test things), but in production it violates security guidelines and introduces complexity. We prefer Option 2 where the admin interface remains internal.

*(For completeness: we did research if newer Soju versions have added any form of network admin API. As of v0.8.x and even looking at v0.9.0 changelogs, there’s no indication of a native HTTP admin. The focus is on the Unix socket and IRC commands. So, no relief from the software side on this front.)*

## Recommended Solution: **Single-Container Deployment with Soju and Sidecar**

After weighing the options, **the most robust and maintainable architecture** is to **embed the sidecar HTTP API within the Soju container** on Railway (Option 2). This addresses the platform’s constraints while keeping our user provisioning workflow intact.

Here’s a summary of why this is the best approach and how to implement it effectively:

* **Leverages Official Soju Mechanisms:** We continue to use `sojuctl` via the Unix admin socket for all user management. This means user creation, password updates, network additions, etc., happen through Soju’s supported interface and take effect immediately without any service restarts. This is a future-proof approach – if Soju’s internals change, `sojuctl` will likely remain the correct way to administer it.

* **No Cross-Container Hacks:** By running both processes in one container, we eliminate the need for volume sharing or `docker exec`. The sidecar can directly execute commands or even invoke Soju’s Go functions (though we’ll stick to CLI for simplicity). Communication stays on the filesystem (which is fast and secure).

* **Alignment with Railway Best Practices:** Railway doesn’t have a concept of pod sidecars, but it does allow running multiple processes in one container when necessary. The Docker documentation acknowledges that sometimes “you need to run more than one service within a container” and suggests approaches like a wrapper script or supervisord. We will adopt these best practices:

  * Use a lightweight init or script to manage processes. For example, an entrypoint script that launches `soju` and the Node server. This script can use Bash job control or `wait` logic to ensure both processes are managed properly.
  * Optionally, incorporate a process manager if we want advanced features (automatic restarts of a crashed sidecar, etc.), but in many cases a simple script is sufficient and less complex.

* **Maintainability:** All components remain modular in code – we’re not merging the codebases, just co-locating them. The Node sidecar code remains the same (except maybe how it calls sojuctl), and Soju remains untouched. Updates to Soju can be applied by updating the binary in the image, without affecting the sidecar logic. Likewise, we can update the sidecar code independently as long as the interface to Soju (sojuctl commands) stays consistent.

* **Local Development:** We can continue using Docker Compose for development if desired, or we can also run the combined container locally to mimic production. One approach is to maintain two Dockerfiles – one for dev (multiple containers as currently) and one for production (combined). However, it might be simpler to develop using the combined setup too: e.g., run the combined container locally and still connect your Next.js app to the sidecar’s port. Since Next.js likely runs outside of Docker in dev, you’d just point it to localhost\:port of the sidecar. This ensures parity between dev and prod environments.

  * Alternatively, keep using Compose in dev (since it’s working) and just build the combined container for deployment. This is fine, but remember to test the combined image before deploying (to catch any integration issues with the entrypoint script, etc.).

* **Railway Deployment:** Once we have the combined Docker image, deploying to Railway is straightforward. We’ll have a single service (perhaps named “soju-bouncer”) using that image. In the Railway dashboard, we’d attach the PostgreSQL plugin to this service (so that Soju can connect to its DB). We’d set any necessary ENV vars (like database URL, and perhaps sidecar config like an admin API key if any). The service will expose the sidecar’s HTTP port (for the main app to call) – Railway will give it a domain or we can use an internal routing since the main app might also be on Railway/Vercel. For the IRC port, if Railway supports exposing a TCP port, we’d enable that (if not, we might tunnel IRC through WebSocket which can go through the HTTP port – Soju supports WebSocket listeners as seen in the config).

* **Concurrency and Performance:** The sidecar should handle concurrent HTTP requests as before (Node’s built-in concurrency via async/await and its single-thread event loop). Each request that triggers a `sojuctl` call will spawn a short-lived process. Since these processes are local and lightweight, even handling a burst of a few per second should be fine (Go sojuctl starts, sends command, exits). If we anticipate a very high rate of user creations, we could consider pooling or keeping a persistent connection to the admin socket, but that’s likely unnecessary overhead – `sojuctl` is fast. We should however ensure proper parsing of its output as we did, especially for error messages like “user already exists” so we can react accordingly (our sidecar already does this fallback logic to update passwords if the user exists).

* **Error Handling & Monitoring:** With both services in one container, a failure in one could bring down the whole container (depending on how we set it up). This is actually desirable in our case – if Soju crashes, the container should exit and restart (because a sidecar without Soju is useless, and vice versa). By using the `wait -n` approach in the entrypoint, whichever process exits first will cause the container to stop with that exit code. We want Railway to then restart it (Railway typically will restart on crash by default, or we can configure healthchecks). Logging can be combined: ensure both Soju and sidecar log to stdout/stderr. Soju by default logs to stdout; our Node can be set to log to console. These logs will all appear in Railway’s log stream for the service, which is convenient. If that becomes noisy, we could separate them by prefixing log lines or configuring supervisord with separate logs, but initially simplicity is fine.

* **Security:** Because everything is internal, we maintain security. The admin socket isn’t accessible externally at all. The sidecar’s HTTP API can be secured as it was (e.g., if you require an internal token or ensure only the main app can call it). It’s running on a private domain or within the same deployment environment. We should verify that in production, the sidecar endpoints are not publicly accessible without auth (depending on your setup). If the main app is making requests server-side, you might restrict the sidecar API by an internal secret or network policy. On Railway, all services within a project are in a private network, but if the sidecar is exposed on a public URL, anyone could attempt hitting it – so consider an authentication layer for the provisioning API.

In summary, **deploying a single container with both Soju and the provisioning API is the recommended solution**. This design respects Soju’s architecture (using the proper admin socket interface) and adapts it to Railway’s limitations. It avoids unsupported hacks and should be maintainable long-term.

## Other Considerations and Patterns

Before concluding, let’s address a few specific points and best practices that arose from the research:

* **Multi-Process Containers on PaaS:** While one-process-per-container is a mantra, many PaaS users run multiple processes when needed (for example, a web server and a worker in one container for simplicity). The Docker docs explicitly show how to do this safely using wrapper scripts or a process manager. We will follow these guidelines to ensure our container is stable. It’s important to handle child processes correctly (using `tini` or similar) so that things like zombie processes or proper termination aren’t an issue. Railway doesn’t provide something like a Procfile to run multiple services in one app (as Heroku might); instead, we implement it at the Docker level.
* **Railway Volumes:** Railway now supports persistent volumes for data **per service** (e.g., to persist the database or uploaded files). However, it does **not support sharing volumes between separate services** (no equivalent of Docker Compose volumes across services). This means our initial idea of mounting the same volume in two services is not possible on Railway. The single-container approach sidesteps this, since the “shared volume” is just the container’s filesystem. If we need persistence (say for Soju’s data directory), we can attach a Railway Volume to the combined service (mount it at `/var/lib/soju` inside the container). That will ensure user data and backlogs persist across deploys. This is a separate concern from the admin interface, but it’s good to note for production: use Railway’s volume for Soju’s state if you want persistence beyond the database (Soju uses the DB for users/networks and can use the filesystem for message logs or an SQLite DB if not using Postgres).
* **Alternatives in the Community:** In similar self-hosting scenarios (outside Railway), a common solution for Soju user management is exactly what we’re doing – run sojuctl in context. Some have written scripts or small web UIs that call `sojuctl`. Others use the IRC commands via an admin bot. We opted for an HTTP API approach which is more straightforward for integration with our Next.js app. This aligns with patterns like having a small internal admin API for a service that doesn’t natively offer one.
* **Scaling**: If you ever needed to scale out Soju to multiple instances (likely not, since one bouncer can handle many users), the single-container approach would mean you scale the combined unit. That’s fine, but all instances would connect to the same DB and you’d need a way to coordinate user creation (to avoid duplicates). This is beyond our current scope. We assume one Soju instance is sufficient for the user base, and it can handle multiple users/networks itself (Soju is built for multi-user operation).
* **Future Soju Features:** Keep an eye on Soju’s development. If a future version introduces a built-in network admin listener (for example, an HTTPS API or a way to accept sojuctl connections over TCP with auth), that could simplify things. But until then, our approach is the most aligned with the current design.

## Conclusion

The **most robust and maintainable solution** for deploying our IRC bouncer stack on Railway is to **run the Soju service and its admin interface bridge in a single container**. This approach meets Railway’s constraints and retains full functionality:

* We continue using Soju’s recommended runtime administration (through `sojuctl` and the Unix socket) for instant user provisioning.
* We avoid unsupported patterns like cross-service sockets or database hacks, which would be brittle and hard to secure.
* By carefully managing two processes in one container (using Docker entrypoint techniques or a supervisor), we ensure high reliability and easier maintenance.

In effect, we are packaging the **sidecar HTTP API as an integral part of the Soju service**. This consolidated service can be deployed to Railway and should behave just like our development setup, minus the Docker Compose complexity. It addresses the admin interface challenge head-on: since we cannot bring Railway to Soju’s Unix socket, we bring Soju’s socket and the API into the same box.

Moving forward with this plan, be sure to implement proper startup scripts and test the combined container thoroughly. Pay attention to logs and signal handling (to avoid any zombie processes). Once configured, this solution will give us a production-ready deployment of Soju on Railway that supports on-the-fly user management – allowing our main application to create IRC users and networks seamlessly, just as it does in development.

**Sources:**

* Soju manual and community guides for admin interface usage (confirming the Unix socket is the intended admin channel and should not be exposed publicly).
* Docker documentation on running multiple processes in one container, which guided our approach to combine Soju and the sidecar safely.
* Observations from Soju’s behavior (config reload limitations) that reinforce why direct DB tweaks aren’t suitable for real-time changes.
* Railway’s own guidelines and community Q\&A (volumes and service isolation) that confirm we must design within a one-container scope on this platform.
