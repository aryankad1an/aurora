# JTracker

An iOS app for running and tracking cold-mail job outreach. Track the companies
you're targeting, keep recruiter contacts for each, and send cold emails
straight from your own Gmail account using reusable templates — with a running
activity feed of everything you've sent.

Built with SwiftUI, backed by [Supabase](https://supabase.com) for data and
Google (Gmail) OAuth for sending mail.

## Features

- **Companies & contacts** — track target companies and the recruiters/contacts
  at each one.
- **Mail domains** — a company can have several (`stripe.com`, `stripe.dev`).
  Adding a contact looks up their address's domain and suggests the company
  already on file for it, so the same company isn't entered twice; a new work
  domain is added to its company automatically.
- **Cold mail via Gmail** — connect your Google account (OAuth + PKCE) and send
  mail on your own behalf through the Gmail API.
- **Templates** — reusable subject/body templates with placeholders, rendered
  per contact before sending.
- **Profile** — your details are merged into templates so mails are personalized
  automatically.
- **Activity** — every mail sent, hung off a time axis and grouped by day, 50 at
  a time, filterable by All / Replied / Waiting and by search. It stays complete
  even after a company drops off the Home list.
- **Templates** — cards that show each template as it reads, with its
  placeholders highlighted, a ready / needs-attention badge from the editor's own
  checks, duplicate and delete, and a one-tap example to start from.
- **Invalid contacts** — mark a contact invalid when the address bounces or the
  person has left. They drop to their own group at the bottom of the company
  page, are never suggested, and can no longer be mailed — reversibly, and for
  every user, since a dead address is dead for everyone.
- **Reply tracking** — every send records the Gmail thread it started, and the
  app reads those threads back to see who answered. Replies show up in Activity
  and drive Quick Actions.
- **Quick Actions** — Home's headline, and the screen you act from: reply rate
  and counts across the top, then three lanes you can tick and batch-send from —
  everyone still waiting (filtered by how many days they've been quiet), everyone
  who answered (with the first lines of what they said), and everyone who hasn't
  been contacted yet, led by the companies on Home.
- **Sending safely** — every send asks first; a batch holds at most 50 mails
  (Gmail's daily cap and spam heuristics both punish more); a template that
  names one company in plain text says so, and warns before it goes to anyone
  else. Sends are recorded every few mails as a run goes, so a run cut short
  can't lead to anyone being mailed twice, and Stop finishes the mail already
  on its way instead of abandoning it mid-request.

## Architecture

| Layer | Details |
|-------|---------|
| UI | SwiftUI (`JTracker/Views`), tab-based `RootView` |
| State | Observable stores — `JobStore`, `ProfileStore`, `TemplateStore`, `GmailAuthStore` (`JTracker/Models`) |
| Backend | Supabase (Postgres + Row Level Security), accessed via `SupabaseAPI` |
| Auth / mail | Google OAuth for sign-in and Gmail send (`GmailAuth`) |
| Local storage | Keychain for tokens, JSON files for cached state (`JTracker/Support`) |

Data is stored server-side in Supabase tables (`companies`, `recruiters`,
`mail_sends`, profiles, templates). The shared recruiter rows are read by all
users; per-user send state is overlaid from `mail_sends` after decoding.

The valid/invalid flag is the shared `recruiters.is_valid` column, not per-user
state — ruling a contact out is a fact about the address, so it applies to
everyone. It's written only by the dedicated `setRecruiterValidity` call, never
as part of an ordinary field edit, so correcting a bad address can't silently
put the contact back in circulation.

Reply state is the opposite: per-user, on `mail_sends`, because whether someone
wrote back is a fact about one mailbox. `ReplySync` runs two passes over Gmail —
it recovers the thread id for sends made before the app captured them (an exact
`in:sent to:… after:… before:…` lookup, not a guess), then reads each unanswered
thread's headers for a message that isn't ours. Matching inbound mail by sender
address was the obvious alternative and is worse: replies routinely arrive from a
colleague or an applicant-tracking system, and both keep the thread id while
neither keeps the address. Our own messages, out-of-office auto-replies and
bounces are excluded on three different header signals — see `ReplySync`.

## Design

The interface is black and drawn like a chart: a near-black ground ruled as
faint graph paper (`GraphPaper`, behind every screen), light ink, hairline rules,
and a single clay accent. The app forces dark appearance so system chrome
matches. Two files hold all of it — `Support/Palette.swift` (colour and type) and
`Support/DesignSystem.swift` (surfaces, metrics, chips, the selector, buttons,
list chrome, selection mode) — so a screen never picks a colour, a corner radius
or a list style of its own.

The rules the components encode:

- **One surface.** Anything raised is the same paper at the same radius behind
  the same hairline. Depth is a rule, not a shadow.
- **Colour is information.** A card is coloured only when its colour means
  something, and then only as a rule down its leading edge: olive for a reply,
  a heat scale for how long a silence has run, faint for a contact ruled out.
  Decorative tint was removed — when every card was tinted, the tint that
  mattered was invisible.
- **Serif for titles and figures.** Navigation titles, the reply rate, and the
  day counts are set in the system serif; everything else is the system sans. A
  serif numeral among sans labels reads as a headline without being large.
- **Content is paper, controls are glass.** Cards and rows stay paper; what
  floats over them is Liquid Glass. Tapping a card zooms it into its screen,
  and the splash is a graph seen through a glass lens whose droplets fuse into
  it as the app loads.
- **Nothing is lost to one stray tap.** Every sheet that edits something asks
  before Cancel throws the edits away and can't be swiped down while it has
  them (`discardableEdits`); sending, signing out and ruling a contact in or out
  all confirm in a centred alert (`confirmAlert`).
- **System components before custom ones.** Lists are `List`s, so taps, holds
  (context menus), swipes and two-finger multi-select are the system's own.
  Selection mode swaps the tab bar for the system bottom toolbar, as Photos
  does (`selectionActions`); the lane selector is the system segmented control;
  press styles don't buzz on touch-down; and no transition animates a blur.

## Requirements

- Xcode (iOS 27 SDK)
- iOS 27.0+ deployment target
- Swift 5
- A Supabase project and a Google Cloud OAuth iOS client

## Getting started

1. Clone the repo and open `JTracker.xcodeproj` in Xcode.
2. Configure your backend credentials in
   [`JTracker/AppConfig.swift`](JTracker/AppConfig.swift):
   - `supabaseURL` and `supabaseAnonKey` (anon public key — protected by RLS)
   - `googleClientID` and `googleRedirectScheme` (from your Google Cloud OAuth
     iOS client; the redirect scheme is the reversed client ID)
3. Apply any pending schema changes to your Supabase project (see
   [Database schema](#database-schema)).
4. Select an iOS Simulator or device and run (`⌘R`).

## Database schema

Schema changes the app expects, newest first. Run them in the Supabase SQL
editor; each is safe to re-run.

```sql
-- Company mail domains (e.g. {stripe.com, stripe.dev}). A company can have
-- several; the app adds a contact's work domain to its company automatically,
-- and suggests the company from the domain when a contact is added. The
-- backfill seeds each company with the work domains its contacts already use.
alter table companies
  add column if not exists domains text[] not null default '{}';
create index if not exists companies_domains_idx on companies using gin (domains);
update companies c
set domains = sub.domains
from (
  select company_id, array_agg(distinct lower(split_part(email, '@', 2))) as domains
  from recruiters
  where email like '%@%.%'
    and lower(split_part(email, '@', 2)) not in (
      'gmail.com', 'googlemail.com', 'yahoo.com', 'yahoo.co.in', 'ymail.com',
      'outlook.com', 'hotmail.com', 'live.com', 'msn.com', 'icloud.com', 'me.com',
      'mac.com', 'aol.com', 'proton.me', 'protonmail.com', 'rediffmail.com',
      'zoho.com', 'gmx.com', 'mail.com', 'yandex.com')
  group by company_id
) sub
where sub.company_id = c.id and c.domains = '{}';

-- Per-contact greeting override: what goes after "Hi " when the name field
-- can't produce it on its own ("A Bagarwal", a role mailbox). Null derives the
-- greeting from the name and address instead.
alter table recruiters
  add column if not exists greeting_name text;

-- Reply tracking. Gmail's ids for each send, and what came back.
alter table mail_sends
  add column if not exists gmail_message_id text,
  add column if not exists gmail_thread_id  text,
  add column if not exists replied_at       timestamptz,
  add column if not exists reply_from       text,
  add column if not exists reply_snippet    text;

create index if not exists mail_sends_thread_idx
  on mail_sends (user_email, gmail_thread_id);

-- Contacts that bounce, or whose owner has left the company.
alter table recruiters
  add column if not exists is_valid boolean not null default true;
```

Until the `greeting_name` block is applied the app still runs — greetings are
derived from the name and address, as before, and a greeting typed into the
contact form is dropped while the rest of the edit saves.

Until the reply-tracking block is applied the app still runs — sends are recorded without
their Gmail ids and Quick Actions shows no replies — and it says so on the Quick
Actions status strip rather than failing.

### Google OAuth

Reply tracking reads the mailbox, so the app requests `gmail.readonly` alongside
`gmail.send`. Two consequences:

- **Reconnect once after updating.** An existing token was minted without the
  read scope; Gmail rejects reads with a 403 until you disconnect and reconnect
  Gmail from the Profile tab.
- **`gmail.readonly` is a restricted scope.** While the OAuth consent screen is
  in *Testing* it works for listed test users as-is. Publishing an app that uses
  it requires Google's verification and an annual security assessment.

> **Note:** The Supabase anon key and the Google iOS client ID are not secrets —
> iOS clients ship them and rely on Row Level Security and PKCE. Do not, however,
> commit any service-role keys, client secrets, or provisioning profiles (see
> `.gitignore`).

## Project layout

```
JTracker/
├─ JTrackerApp.swift        App entry point
├─ AppConfig.swift          Supabase + Google OAuth configuration
├─ Models/                  Data models and observable stores
├─ Views/                   SwiftUI screens
├─ Support/                 Keychain, JSON persistence, theming
└─ Assets.xcassets/         App icon and colors
```
