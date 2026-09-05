# App Store Connect Listing — WHYTE ROUTES

Corrected for accuracy against what's actually shipped (see notes at bottom)
and trimmed to fit Apple's field limits. Copy-paste ready.

## Subtitle (30 char max)
```
Fleet Dispatch & Field Ops
```
26 chars.

## Promotional Text (170 char max — editable anytime without a new review)
```
Route optimization, live GPS dispatch, and driver navigation built for landscaping and snow removal crews. Know where every truck is, in real time.
```
150 chars.

## Keywords (100 char max, comma-separated, no spaces needed after commas)
```
landscaping,snow removal,dispatch,route optimization,fleet tracking,GPS,lawn care,field service
```
97 chars.

## Description (4000 char max)
```
WHYTE ROUTES
The Fleet Dispatch and Field Operations Platform for Landscaping & Property Service Businesses

WHYTE ROUTES is a professional fleet dispatch, route optimization, and field operations platform built specifically for landscaping, snow removal, lawn care, property maintenance, and mobile service companies.

It helps business owners, dispatchers, and drivers stay connected through intelligent route planning, live GPS tracking, and real-time dispatch. Whether a company operates one truck or an entire fleet, WHYTE ROUTES is designed to reduce wasted travel, improve communication, and increase productivity.

THE PROBLEM WE SOLVE
Service businesses face the same daily challenges: drivers wasting time on inefficient routes, dispatchers constantly fielding "where is my crew?" calls, crews finishing early while others fall behind, manual route planning, paper schedules, and no centralized view of the day's operations. WHYTE ROUTES solves these with one connected platform.

WHO USES WHYTE ROUTES

Business Owners have complete control over daily operations: create and manage the company, manage employees and permissions, build and optimize routes, assign drivers, monitor live crews, view operational reports, configure company settings, and manage subscriptions.

Dispatch Managers coordinate field operations throughout the day: build optimized daily routes, assign or reassign drivers, move stops between active routes live without interrupting drivers, monitor vehicle locations, mark stops complete or reopen them, and balance workloads across crews.

Drivers receive their assigned work automatically. The experience is built around safety and simplicity: clock in/out, view assigned routes, navigate to each stop, see customer notes, contact customers when needed, report issues, and complete stops with automatic progression to the next one.

CORE PLATFORM FEATURES

Fleet Management — multi-company support, driver management, role-based permissions (owner/manager/driver), company settings.

Intelligent Route Planning — route creation with nearest-neighbor + 2-opt optimization, drag-and-drop stop ordering, address autocomplete, multi-driver routing.

Live Dispatch — real-time GPS tracking of every driver, route progress, current/next stop, fleet overview on a live map.

Live Route Management — dispatchers can mark stops complete or incomplete, move a stop from one driver's route to another's, and reassign drivers, all with changes written immediately so nothing goes stale mid-shift.

Built-In Driver Navigation — turn-by-turn driving directions with spoken voice guidance inside the app: the next maneuver and the remaining time and distance stay on screen, every turn is announced out loud, and the route recalculates on its own if a driver comes off it — with no switching out to a separate map app.

Customer Tracking Links — customers get a link showing their queue position, and live driver location with a real ETA once the driver is on the way to them.

Reporting — completed stops, route duration, distance traveled, and time spent per stop, broken down by driver.

COMING SOON
Recurring route templates and before/after photo proof of work.

INDUSTRIES SERVED
Landscaping, lawn care, snow removal, property maintenance, tree services, irrigation, pressure washing, window cleaning, pool maintenance, pest control, junk removal, and other exterior property services.

WHAT MAKES WHYTE ROUTES DIFFERENT
General routing apps help drivers find destinations. General landscaping software helps businesses create estimates and invoices. WHYTE ROUTES manages what happens between those two steps — the daily operation of running crews in the field. It's built to become the operational hub landscaping and property service companies rely on every day.
```
Character count: 3,792 of the 4,000 limit (recounted 2026-09-05 after
promoting Customer Tracking Links). ~200 chars of headroom; anything
added now has to come out of something else. Recount before submitting.

---

## Accuracy notes — what changed from your draft and why

- **Rewrote Driver Navigation for the in-app engine.** The line said the app launches Apple Maps, Google Maps or Waze with company-configured avoid-tolls/highways preferences. There is no external map hand-off left anywhere in the app: `NavigationSession` builds the route with `MKDirections`, tracks which maneuver the driver is on, and speaks each one through `AVSpeechSynthesizer`. Two separate claims in that one sentence were wrong — the three map apps, and "company-configured." `NavigationSession` does still read `avoidTolls`/`avoidHighways` off the company document, but `NavigationSettingsView` is gone, so nothing in the app lets an owner set them; they sit on whatever was last written, or the defaults. A preference no customer can find is the same Guideline 2.3.1 problem as a feature that isn't there, so the new line claims neither.
- **Dropped "a hands-free driver mode with voice guidance and automatic arrival detection" from COMING SOON.** Both halves ship: the voice guidance is the engine above, and arrival detection is `LocationService`'s 40 m geofence, which is what stamps `arrivedAt` and fires the customer's arrival text. Leaving it under COMING SOON would have contradicted the Driver Navigation line a few paragraphs above it.
- **"Configure navigation and company settings" is now just company settings**, for the same reason — there is no navigation settings screen to send an owner to.
- **RESOLVED 2026-09-05 — all three walked end-to-end in code.** Customer tracking links are FUNCTIONAL (DriverSession.startShift → TrackingBroadcastService → trackingLinks/{id}/location/current, read by the deployed track.html; links auto-sent in shift-start texts and manually from EditRouteView) and were promoted into the feature list above. The earlier note that "the live-location write path was never wired up" was stale. Caveat: tracking requires a paid tier (functions/index.js tierRank ≥ 1), and sends are release-build only. Photo proof is NOT wired (driver button intentionally hidden for the snow beta; ManagerPhotoProofView not in the build target and reads a nonexistent top-level `stops` collection) and route templates are dead code excluded from the target — both stay under COMING SOON.
- **Removed "Automatically progress through their route" as a customer-facing headline claim** but kept it in the Drivers section since it IS real — `DriverStopViewModel.markCompleted()` does auto-advance to the next stop. This one's accurate, kept as-is.
- **Dropped "Bulk imports," "predictive dispatching," "AI-assisted operational planning"** from the shipped feature list — these were already marked speculative/future in your draft, just trimmed for length since they don't need to be in the initial listing at all.
- Everything else (multi-company support, role-based permissions, route optimization, drag-and-drop reordering, address autocomplete, live GPS tracking, live route management/reassignment, reporting) matches what's actually built and shipped this session — kept as-is.
