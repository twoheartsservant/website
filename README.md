# Two-Hearts Servant Community — Deployment Package

A multi-page Catholic youth/community website with a maroon-and-cream visual theme. It has separate HTML pages, shared CSS and JavaScript, Supabase authentication, a shared events database, private member registrations, and an organizer dashboard protected by database Row Level Security (RLS).

## Included files

- `index.html` — Home
- `about.html` — About the community
- `events.html` — Public events list and filters
- `ministries.html` — Ministry teams and roles
- `register.html` — Volunteer application form
- `registrations.html` — Signed-in member's own applications
- `login.html` — Create account / sign in
- `admin.html` — Restricted organizer dashboard
- `style.css` — Shared design and responsive styling
- `app.js` — Frontend behavior and Supabase integration
- `config.js` — Public Supabase project configuration
- `supabase_schema.sql` — Tables, triggers, ministry-specific capacity checks, aggregate counts, and RLS policies

## 1. Create and configure Supabase

1. Create a project at [Supabase](https://supabase.com/).
2. Open **SQL Editor** in the Supabase dashboard.
3. Paste and run the complete contents of `supabase_schema.sql`. If this is an existing project, make a database backup first. This updated schema adds ministry-specific targets, public aggregate counts, the Postponed/Cancelled event statuses, and cascading event deletion.
4. Open **Project Settings → API** (or the project's API keys page) and copy the **Project URL** and the **publishable/anon public key**.
5. Open `config.js` and replace `YOUR_SUPABASE_PROJECT_URL` and `YOUR_SUPABASE_ANON_KEY` with those values.
6. Never place a `service_role` or secret key in `config.js`, HTML, JavaScript, or any file deployed to a browser.

The database starts with **no sample events and no sample volunteer registrations**. Add real events from the organizer dashboard after the first organizer account is configured.

## 2. Create your organizer account

1. Deploy or run the site, then open `login.html` and create an account using the email you control.
2. Confirm the account email if email confirmation is enabled in Supabase.
3. In Supabase SQL Editor, run the following statement after replacing the email with your organizer account's exact email:

```sql
update public.profiles p
set role = 'admin'
where p.id = (
  select u.id from auth.users u
  where lower(u.email) = lower('organizer@example.com')
);
```

4. Sign in through `login.html`, then open `admin.html`. The dashboard should show event management and volunteer applications only for the account whose database profile has `role = 'admin'`.

Do not make the profile role editable in the public website. Admin roles must be assigned only by a trusted project owner through the database dashboard.

## 3. Run the website locally

**Do not double-click `index.html` to open it as a `file://` page.** Supabase authentication and browser requests need an HTTP origin. Start a local web server from this folder instead.

For example, if Python is installed, open a terminal in this folder and run:

```bash
python -m http.server 8000
```

Then open `http://localhost:8000`. If Supabase email confirmation is enabled, add your local and deployed site URLs to **Authentication → URL Configuration** in Supabase. Add the appropriate redirect URLs for your deployment provider.

## 4. Deploy the static website

Upload the contents of this folder to any static host that serves ordinary HTML, CSS, and JavaScript (for example, Netlify, Cloudflare Pages, or GitHub Pages). Keep the page files at the same directory level so the navigation links work. Set the site's root to this folder and configure the deployed site URL in Supabase Authentication URL settings.

## How registration security works

- Visitors can read events that are not drafts; draft events are visible only to admins.
- A volunteer must sign in before applying.
- Members can read only their own registrations; admins can review all registrations.
- Database RLS checks that an applicant submits a registration for their own account.
- Database triggers check that the event is currently `Open`, has overall capacity, and has room in the selected ministry target, even if someone bypasses the form in their browser.
- Event organizers can set targets like `Media Ministry: 3, Music Ministry: 2`, filter events by ministry, mark events Postponed or Cancelled, and delete events with their related registrations.
- Public ministry counts expose aggregate totals only, not volunteer names or contact information.
- Organizer functions require an admin role stored in `profiles`; hiding a link is not the security boundary.
- The database has no seeded event records. The organizer must add at least one ministry target to each event before volunteer applications can be accepted. An organizer must create events and set their status to `Open` to accept applications.

## Before accepting real personal data

Review the community's privacy notice and consent wording, decide who may access volunteer information, and test account creation, email confirmation, event capacity, and admin permissions in a test project. Configure backups and your organization's data retention process. This package provides the app and database security policies, but it cannot create your Supabase project, configure its email provider, or publish a live URL on your behalf.
