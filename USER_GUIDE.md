# queue_q – User Guideline

[中文版 (Chinese version)](USER_GUIDE_ZH.md)

## About queue_q

queue_q lets patients join a clinic room's queue from their own phone, then wait anywhere until their turn. There is no app to install and no login.

There are two kinds of users:

- **Patients** scan a room's QR code to get a ticket number, and their phone rings when it's their turn.
- **Room staff** use the room's host page on a computer or tablet to call patients.

### Your clinic's rooms

| Room | Ticket letter | Patient QR code / join link | Host page link |
| --- | --- | --- | --- |
| Physio Dr1 | A |  |  |
| consultation 1 | B |  |  |

The website is **queueq.netlify.app**. QR codes and links come from the admin page under **Show QR code and links**. Each room's PIN is given only to that room's staff.

## For patients

### Join a queue

1. Scan the room's QR code with your phone camera, and tap the link that appears. On a computer, paste the room's join link into the browser instead.
2. The page shows the room name, how many people are waiting, and your expected wait.
3. The first time, type your name. Phone number is optional.
4. Tap **Join the queue**. You get a ticket number, like **A001**.
5. Tap **Turn on sound alerts** so your phone rings when it's your turn.

### Read your ticket

| What the ticket says | What it means |
| --- | --- |
| Wait about 15 min | Your estimated waiting time, with the number of people ahead |
| You're next | You're first in line. Stay nearby |
| Please go to \[room\] now | It's your turn. The phone rings and shows a full green screen |
| Your place is kept while you're in \[other room\] | You're being seen in another room. Your place here is held for you |
| Earlier today | Finished, missed or left queues from today |

### Wait in more than one room

Scan another room's QR code and tap **Join the queue**. You won't be asked for your name again. All your tickets show on one page.

While you're with one room, your other queues are put on hold. When you finish, you go next in those rooms, right after whoever is being seen at that moment.

### Other actions

- **Let the next person go first:** swaps places with the person behind you. Useful if you need a few more minutes.
- **Leave this queue:** removes you from that room's queue. You lose your place.
- **Use this phone for another patient:** clears your tickets from this phone, so someone else can use it.

Keep the queue page open with the screen on while you wait. A locked phone may not ring, especially an iPhone.

## For room staff

### Open the host page

1. Open the room's host link on the room's computer or tablet.
2. Enter the room PIN (numbers only) and click **Open host page**. The device remembers it, so you only do this once.
3. To stop the device remembering it, click **Lock this device (forget PIN)** at the bottom of Room settings.

After 10 wrong PINs, the host page locks for 5 minutes.

### Buttons

| Button | What it does |
| --- | --- |
| Call next | Calls the first patient in line. Their phone rings |
| Finish and call next | Ends the current patient and calls the next one |
| Finish | Ends the current patient without calling anyone |
| Ring again | Rings the current patient's phone again |
| No-show | Moves a patient who didn't come to the No-shows list |
| Put back in line | Returns a no-show patient to their original place |
| Call now | Calls a specific patient out of order, for example an elderly patient |
| Minutes (e.g. 10 min) | Changes that patient's estimated time. Leave it empty to use the room default |

Patients marked **In \[other room\]** are being seen elsewhere. They can't be called until they finish there, so Call next skips them and keeps their place.

### Room settings

- **Open:** normal.
- **On break:** patients can still join and see your message, e.g. "Back at 2:00 PM".
- **Closed:** no new patients can join.
- **Default minutes per patient:** used for every patient's estimate unless you change one.

Click **Save settings** after any change. The stats box under the current patient shows today's count of patients seen and the average minutes per patient.

## Common questions

| Problem | What to do |
| --- | --- |
| My phone didn't ring | Tap **Turn on sound alerts**, keep the queue page open and the screen on. A locked phone may not ring, especially an iPhone |
| I closed the page | Scan any room's QR code again, or open queueq.netlify.app on the same phone and browser. Your tickets are still there |
| It asks for my name again | You're on a different phone or browser. Use the one you joined with |
| I missed my turn | Tell the room staff. They can put you back in line |
| The host page asks for a PIN | Enter the room's PIN. Ask the clinic admin if you don't have it |
| "Too many wrong PINs" | Wait 5 minutes, then try again |
| The screen isn't updating | Pull down to refresh, or press F5 on a computer |

For anything else, ask the clinic's front desk.
