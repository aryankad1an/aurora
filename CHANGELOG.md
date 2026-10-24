# Changelog

## Unreleased

- **Widgets.** *Aurora* draws the week as a striped sunset, one band a day,
  with the reply rate, the streak, two weeks of sends and replies and the next
  send, in every Home Screen size and on the Lock Screen. *Replies* lists who
  wrote back. Replies found by a background check show up on them before the
  app is opened. They hold counts, company names and repliers' names only,
  and empty out at sign-out.
- **Replies on a company's page**: who there wrote back, newest first, with
  what they said; tap one to open the mail and the reply.
- **Forgot your private key?** Settings › Sharing & Keys can reset it with the
  recovery phrase in place of the current key.
- **Faster search, and by every word.** "juniper chloe" finds Chloe at
  Juniper Cloud, on the phone and in the shared catalog. Text is folded once
  and reused instead of on every keystroke.
- **Black, not brown.** The ground is true black, with brighter accents.
- **Filters in a menu.** Companies' fresher and hiring-route filters moved from
  chips to a filter button in the top bar.

## 2.1

### One queue, paused and played as a whole

- **Pause stops everything.** Pausing used to stop only the batch on screen,
  and the next company's batch started straight after. Now Pause holds the
  whole queue: the mail already on its way finishes, and nothing else goes
  until you tap Resume.
- **Resume plays the queue from the front**, in the order it was queued, each
  mail once. Mail you queue while it's paused waits in line behind the rest.
- **A pause survives a relaunch.** The queue opens paused if you left it
  paused.
- **A batch the queue stopped holds up the line.** When the queue stops one
  batch itself (too many dropped connections, a long Gmail limit), the batches
  behind it wait instead of starting, and one Resume carries on from it.
- Removing the stopped batch, rescheduling it or clearing mail leaves the
  queue paused. Emptying the queue lets go of the pause, so the next send isn't
  held up by an old one.
- The shelf says "Queue paused · 6 to go" with who's next, and has a Resume
  button. The Queued lane has one Pause Queue or Resume Queue button for the
  whole queue in place of a button on each batch.

### Replies and bounces checked in the background

- **Checks while the app is closed.** iOS runs a short check every so often
  (at most every 30 minutes, as it sees fit). It reads only threads and failure
  notices, a few dozen of each, paced like every read so it stays well inside
  Gmail's read limit. Anything over that is left for the next check, never
  skipped. After Gmail asks to slow down, the next check waits an hour.
- **A check carries on when you leave the app.** A check that runs past a few
  seconds on screen asks iOS for time to finish (`BGContinuedProcessingTask`),
  so a long check no longer freezes partway and starts over.
- **A Live Activity for long checks**, with the step, progress, and the
  replies and bounces found when it ends. It steps aside for the system's card
  and for the send queue's own activity, so there's only ever one.
- **A notification for everything found** with the app off screen: one per
  reply, and one for each check's bounces. Tapping one opens Activity on the
  Replied or Bounced lane.
- The Status timeline marks checks that ran in the background, and says when
  one ran out of time.

### Bounces that were missed

- **Notices from mail filters and company relays count.** Mimecast's
  "[Postmaster] Email Delivery Failure", or an Exchange tenant's "Your message
  couldn't be delivered" from a no-reply address, come with no report and from
  nobody's mailer daemon. They're now recognised by their subject and their
  text together, while replies and forwards about a bounce are not.
- **Notices sent as HTML alone are read.** Their text is taken from the HTML
  part when there's no plain-text one.
- **More subjects are searched for**: "couldn't be delivered", "could not be
  delivered", "not delivered" and "delivery failed".
- **Old notices are read again once.** Notices an older version passed over are
  searched for across the whole window on the first check after updating.

### Live Activity fixes

- A scheduled batch's card that had gone stale was taken for gone: a second
  card went up beside it, and one left by an earlier launch was never taken
  over. Both now count as up.
- A card swiped away no longer comes straight back for the same batch or
  check.
- With the app suspended mid-run, the sending and checking cards used to freeze
  on "Sending mail" or "Checking" for hours. Each is now marked stale three
  minutes after the app last updated it ("Paused · open Aurora to carry on",
  "Check paused"), and a running card is renewed every minute while the app
  can.
- The send card is no longer requested from the background, where iOS refuses
  it, on every change of the queue.
- The writing card no longer counts up forever when you don't come back from
  Shortcuts: it says it stopped waiting once Aurora has.
- Send Now on a stale card only acts on a batch that's still waiting for its
  time. It can no longer restart a batch that had begun, or play a queue you'd
  paused.

## 2.0

- **A new look.** One retro motion-graphics style in place of the themes: a
  warm black ground under film grain, cream type, a burnt-orange accent, and a
  striped sun. The launch screen is an ident, and sending plays a short
  full-screen "Queued" curtain.
- **Writing help through Aurora Writer.** A shortcut of your own runs Apple
  Intelligence's Use Model action to proofread, rewrite or draft, and every
  change is shown word by word before it's applied.
- **A personalised line per company.** `{Company-Personalised}` puts a
  sentence you wrote about a company into every mail to people there.
- **Fresher hiring.** Companies from the Fresher Hiring Ledger are flagged and
  filterable, with their logos, websites, careers pages, hiring routes, stated
  packages and the sources behind them.
- **Sending you can leave.** The queue carries on in the background, never
  mails anyone twice, and shows one Live Activity from the first mail to the
  bounce check.
- **Replies read from new mail only**, with a Status timeline of each check,
  and **Export Data** to JSON or spreadsheets.
