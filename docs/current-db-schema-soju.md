I'll help you research the identity system of the IRC bouncer. Let me start by exploring the bouncer directory structure and then look for database information.
Ran tool

Read file: ../curia-irc-bouncer/soju.conf

Read file: ../curia-irc-bouncer/Dockerfile

Read file: ../curia-irc-bouncer/entrypoint.sh

Read file: ../curia-irc-bouncer/init-user.sh

Read file: ../curia-irc-bouncer/README.md

```bash
find ../curia-irc-bouncer -name "*.sql" -o -name "*schema*" -o -name "*dump*" -o -name "*migration*"
```

```bash
find .. -name "docker-compose.yml" -o -name "docker-compose.yaml"
```

Read file: ../docker-compose.yml

```bash
docker ps | grep curia-irc
```

```bash
docker exec -it curia-irc-postgres psql -U soju -d soju -c "\dt"
```

```bash
docker exec curia-irc-postgres psql -U soju -d soju -c "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public';"
```

```bash
docker exec curia-irc-postgres psql -U soju -d soju -c "\\d+ \"User\""
```

```bash
docker exec curia-irc-postgres psql -U soju -d soju -c "\\d+ \"Network\""
```

```bash
docker exec curia-irc-postgres psql -U soju -d soju -c "SELECT id, username, admin, nick, realname, enabled, created_at FROM \"User\";"
```

```bash
docker exec curia-irc-postgres psql -U soju -d soju -c "SELECT id, name, \"user\", addr, nick, username, enabled FROM \"Network\";"
```

```bash
docker exec curia-irc-postgres psql -U soju -d soju -c "SELECT COUNT(*) as channel_count FROM \"Channel\"; SELECT COUNT(*) as message_count FROM \"Message\";"
```

# **🔍 SOJU IRC BOUNCER IDENTITY SYSTEM ANALYSIS**

Based on my investigation of the database schema and current setup, here's the complete picture of the identity system:

## **📊 DATABASE SCHEMA OVERVIEW**

### **Core Identity Tables**:

#### **1. `User` Table** (Primary Identity)
```sql
- id: integer (Primary Key)
- username: varchar(255) (Unique) 
- password: varchar(255) (Nullable - for internal auth)
- admin: boolean (Default: false)
- nick: varchar(255) (Nullable - default IRC nick)
- realname: varchar(255) (Nullable - IRC real name)
- enabled: boolean (Default: true)
- created_at: timestamp
- downstream_interacted_at: timestamp (Last client interaction)
```

#### **2. `Network` Table** (Per-User IRC Networks)
```sql
- id: integer (Primary Key)
- name: varchar(255) (Network name, e.g., "commonground")
- user: integer (Foreign Key → User.id)
- addr: varchar(255) (IRC server address)
- nick: varchar(255) (User's nick on this network)
- username: varchar(255) (IRC username)
- pass: varchar(255) (Network password)
- sasl_mechanism: enum (SASL auth type)
- sasl_plain_username/password: varchar(255)
- enabled: boolean (Default: true)
```

#### **3. Supporting Tables**
- **`Channel`**: User channel memberships per network
- **`Message`**: Message history storage 
- **`DeliveryReceipt`** & **`ReadReceipt`**: Message delivery tracking
- **`WebPushSubscription`**: Push notification settings

## **🏗️ CURRENT SYSTEM STATE**

### **Existing Users**:
```
admin (ID: 1)
├── Admin: true
├── Created: 2025-07-31 20:39:08
├── Networks: 1 (commonground)
└── Status: enabled
```

### **Network Configuration**:
```
commonground (ID: 2)
├── User: admin (ID: 1) 
├── Address: irc+insecure://ergo:6667
├── Status: enabled
└── Channels: 3 active channels
```

### **Activity**:
- **3 channels** joined
- **31 messages** in history
- **Bouncer operational** and storing data

## **🔑 IDENTITY BRIDGE OPPORTUNITIES**

### **Current Authentication Mode**: 
**Internal (Development)** - Users created via `sojuctl`

### **Production Authentication Mode**:
**HTTP Auth** via `SOJU_AUTH_URL` (commented out in config)

## **🎯 IDENTITY BRIDGING STRATEGY**

### **Option 1: HTTP Authentication Bridge** ⭐ **RECOMMENDED**

**How it works**:
1. **Enable HTTP auth** in `soju.conf`: `auth http ${SOJU_AUTH_URL}`
2. **Create API endpoint** in Curia: `/api/irc-auth`
3. **User flow**: The Lounge → Soju → Curia API → User validation

**Implementation**:
```typescript
// In Curia app: /api/irc-auth
POST /api/irc-auth
Authorization: Basic <base64(username:password)>

// Response: 200 OK (valid) or 403 Forbidden (invalid)
// Soju automatically creates User record if auth succeeds
```

**Benefits**:
- ✅ **Seamless SSO** - Users use CG credentials
- ✅ **Automatic user creation** - No manual provisioning
- ✅ **Session management** - Follows CG authentication
- ✅ **Security** - CG handles password verification

### **Option 2: Pre-provisioned User Creation**

**How it works**:
1. **Create Soju users** when CG users first access chat
2. **Generate random passwords** stored in CG database  
3. **Pass credentials** to The Lounge via URL parameters

**Implementation**:
```typescript
// When opening chat modal:
1. Check if IRC user exists for CG user
2. If not: Create via sojuctl API
3. Pass credentials to The Lounge
```

### **Option 3: Token-Based Authentication**

**How it works**:
1. **Generate IRC tokens** in CG app
2. **Map tokens to users** in bridge service
3. **Validate tokens** via HTTP auth endpoint

## **🛠️ RECOMMENDED IMPLEMENTATION PLAN**

### **Phase 1: HTTP Auth Bridge Setup** (2-3 hours)

1. **Create `/api/irc-auth` endpoint** in Curia:
```typescript
// pages/api/irc-auth.ts
export default async function handler(req: NextRequest) {
  const auth = req.headers.authorization;
  const [username, password] = parseBasicAuth(auth);
  
  // Validate against CG user system
  const isValid = await validateUser(username, password);
  
  return isValid ? 
    Response.json({ success: true }, { status: 200 }) :
    Response.json({ error: 'Invalid credentials' }, { status: 403 });
}
```

2. **Enable HTTP auth** in Soju:
```bash
# Uncomment in soju.conf:
auth http http://host.docker.internal:3000/api/irc-auth
```

3. **Update The Lounge URL** to use CG credentials:
```typescript
const chatUrl = `${baseUrl}?username=${cgUser.username}&password=${cgUser.sessionToken}&autoconnect&nick=${cgUser.username}&join=%23general`;
```

### **Phase 2: User Mapping & Network Auto-creation** (1-2 hours)

1. **Automatic network creation** when user first authenticates
2. **Username consistency** between CG and IRC
3. **Channel auto-join** based on community context

### **Phase 3: Advanced Integration** (2-3 hours)

1. **Community-specific channels** 
2. **User presence synchronization**
3. **Message notification bridge**

## **🔧 TECHNICAL REQUIREMENTS**

### **Environment Changes**:
```bash
# Add to docker-compose.yml soju service:
SOJU_AUTH_URL: "http://host.docker.internal:3000/api/irc-auth"
```

### **Database Changes**:
- **No schema changes needed** - Soju handles user creation automatically
- **Optional**: Add `irc_username` field to CG users table for mapping

### **Security Considerations**:
- **HTTPS required** for production auth endpoint
- **Rate limiting** on auth endpoint to prevent brute force
- **Token expiration** for session management
- **Audit logging** for IRC access

## **📈 SUCCESS METRICS**

### **Identity Bridge Success Criteria**:
- [ ] **Single Sign-On**: CG users can access IRC with their CG credentials
- [ ] **Automatic provisioning**: First-time users get Soju accounts automatically  
- [ ] **Username consistency**: Same username in CG and IRC
- [ ] **Session management**: IRC access follows CG session lifecycle
- [ ] **Security**: No password exposure, proper authentication flow

---

**The Soju identity system is well-structured and ready for CG integration!** The HTTP auth bridge approach provides the cleanest path to seamless user experience while maintaining security and proper session management.

**Next step**: Should I proceed with implementing the HTTP auth bridge API endpoint?