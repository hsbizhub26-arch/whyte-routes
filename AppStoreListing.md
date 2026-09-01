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

Reporting — completed stops, route duration, distance traveled, and time spent per stop, broken down by driver.

COMING SOON
Customer-facing live tracking links, recurring route templates, and before/after photo proof of work.

INDUSTRIES SERVED
Landscaping, lawn care, snow removal, property maintenance, tree services, irrigation, pressure washing, window cleaning, pool maintenance, pest control, junk removal, and other exterior property services.

WHAT MAKES WHYTE ROUTES DIFFERENT
General routing apps help drivers find destinations. General landscaping software helps businesses create estimates and invoices. WHYTE ROUTES manages what happens between those two steps — the daily operation of running crews in the field. It's built to become the operational hub landscaping and property service companies rely on every day.
```
Character count: 3,672 of the 4,000 limit — roughly 330 characters of
headroom, not the comfortable margin the old "~2,850" note promised.
That figure was already about 700 low before this pass, so the advice
that there was room to add detail back was wrong when it was written.
Anything added here now has to come out of something else; recount
before submitting.

---

## Accuracy notes — what changed from your draft and why

- **Rewrote Driver Navigation for the in-app engine.** The line said the app launches Apple Maps, Google Maps or Waze with company-configured avoid-tolls/highways preferences. There is no external map hand-off left anywhere in the app: `NavigationSession` builds the route with `MKDirections`, tracks which maneuver the driver is on, and speaks each one through `AVSpeechSynthesizer`. Two separate claims in that one sentence were wrong — the three map apps, and "company-configured." `NavigationSession` does still read `avoidTolls`/`avoidHighways` off the company document, but `NavigationSettingsView` is gone, so nothing in the app lets an owner set them; they sit on whatever was last written, or the defaults. A preference no customer can find is the same Guideline 2.3.1 problem as a feature that isn't there, so the new line claims neither.
- **Dropped "a hands-free driver mode with voice guidance and automatic arrival detection" from COMING SOON.** Both halves ship: the voice guidance is the engine above, and arrival detection is `LocationService`'s 40 m geofence, which is what stamps `arrivedAt` and fires the customer's arrival text. Leaving it under COMING SOON would have contradicted the Driver Navigation line a few paragraphs above it.
- **"Configure navigation and company settings" is now just company settings**, for the same reason — there is no navigation settings screen to send an owner to.
- **UNRESOLVED — COMING SOON now probably understates the app.** The note below about customer tracking links was true when it was written and isn't any more: `TrackingBroadcastService` publishes queue position to every waiting customer and live coordinates plus a real ETA to the one being driven to, `hosting/track.html` is deployed, and the privacy policy already describes the feature as live. `PhotoProofView`/`ManagerPhotoProofView` and `RouteTemplate`/`RouteManagerView` exist too. Understating costs nothing at review, so none of the three were promoted here on the strength of a file existing — but each should be walked end-to-end before submission and moved up if it works.
- **Cut customer-tracking claims down to "Coming soon."** Your draft described a secure tracking link with live location, ETA, queue position, and arrival/completion notifications, presented as available now. The screen exists in the codebase but the live-location write path was never wired up — nothing actually populates it. Listing it as a working feature risks an App Review rejection (Guideline 2.3.1, inaccurate metadata) and, worse, a real customer clicking a tracking link that shows nothing.
- **Moved Route templates and Route duplication to "Coming soon."** Neither exists in the app yet — there's no recurring-route generator and no duplicate-route action anywhere in the codebase.
- **Removed "Automatically progress through their route" as a customer-facing headline claim** but kept it in the Drivers section since it IS real — `DriverStopViewModel.markCompleted()` does auto-advance to the next stop. This one's accurate, kept as-is.
- **Dropped "Bulk imports," "predictive dispatching," "AI-assisted operational planning"** from the shipped feature list — these were already marked speculative/future in your draft, just trimmed for length since they don't need to be in the initial listing at all.
- Everything else (multi-company support, role-based permissions, route optimization, drag-and-drop reordering, address autocomplete, live GPS tracking, live route management/reassignment, reporting) matches what's actually built and shipped this session — kept as-is.
