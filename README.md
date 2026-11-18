# queue_q

A free, no-login queue system for clinics with multiple rooms.

- Each room has its own QR code. Patients scan it, enter their name, and get a ticket (A001, B001…).
- A patient can wait in several rooms at once. While they are in treatment in one room, their place in the other rooms is kept ("on hold"). When they finish, they go next in those rooms, right after whoever is currently being served.
- The room host sets the estimated minutes per patient (room default or per patient). Patients see their estimated wait.
- Patients' phones ring (sound, vibration, notification) when it's their turn.
- Ticket numbers restart every day automatically.

Files:

- `public/index.html` — the whole app (patient, host and admin pages)
- `supabase/schema.sql` — the database, rules and security

## Setup (about 15 minutes, free)

### 1. Create the database (Supabase, free plan)
1. Sign up at https://supabase.com and create a new project. Choose the Singapore region (closest to Malaysia).
2. Open **SQL Editor → New query**.
3. Open `supabase/schema.sql`, change `change-this-password` on the last line to your own admin password, paste the whole file and click **Run**.
4. Click **Connect** (top of the dashboard) or go to **Project Settings → API Keys**, and copy the **Project URL** and the **publishable key** (starts with `sb_publishable_`). Do not use the secret key.

### 2. Configure the app
Open `public/index.html` and fill in the three lines near the top:

```js
const SUPABASE_URL = 'https://xxxx.supabase.co';
const SUPABASE_KEY = 'sb_publishable_...';
const CLINIC_NAME = 'Your Clinic Name';
```

The publishable key is safe to put in the page. Browsers can only read room names and call the queue functions; patient names and PINs stay locked in the database.

### 3. Put it online (Netlify, free plan)
1. Sign up at https://netlify.com with your GitHub account.
2. **Add new project → Import an existing project → GitHub**, and pick this repository.
3. Set **Publish directory** to `public`. Leave the build command empty.
4. Click **Deploy**. Every time you push changes to GitHub, Netlify updates the site automatically.

Only the `public` folder goes online. Never commit `schema.sql` with your real admin password in it; keep `change-this-password` in the repo and only type your real password in the Supabase SQL Editor.

### 4. Add rooms
1. Open `https://your-site/?admin` and sign in with your admin password.
2. **Add a room**: name, ticket letter, minutes per patient, host PIN.
3. Click **Show QR code and links** → **Print QR poster** and post it at the room.
4. Open the **host link** on the room's computer or tablet and enter the PIN once.

## Pages

| Address | Who | What |
|---|---|---|
| `/` | Patient | My queues (all rooms, estimated waits, alerts) |
| `/?room=…&t=…` | Patient | Join page (opened from the QR code) |
| `/?host=ROOM-ID` | Room host | Call next, finish, ring again, no-show, set minutes, open/break/closed |
| `/?admin` | Clinic admin | Add/edit rooms, PINs, QR codes |

## Good to know

- **Alerts:** patients should tap **Turn on sound alerts** and keep the page open. On iPhone, notifications only work when the site is added to the Home Screen, so the sound and the full-screen "It's your turn" message are the main alert.
- **Security:** after 10 wrong PINs a room's host page locks for 5 minutes. **Make a new QR code** in admin if a QR photo is being shared outside the clinic; old printed codes stop working.
- **Free plan limits:** Supabase pauses free projects after 7 days with no activity. A clinic using it daily won't hit this.
- **Timezone** is set to `Asia/Kuala_Lumpur` in the `settings` table.

## Ideas for later
WhatsApp/SMS alerts, priority tags (elderly, OKU, pregnant), waiting-area TV display, printed tickets, reports, Bahasa Melayu language option.
