(define-module (pinenote services timesync)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module ((gnu packages linux) #:select (util-linux))
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (srfi srfi-1)
  #:use-module (pinenote packages koreader)
  #:export (pinenote-timesync-service-type
            pinenote-timesync-configuration
            pinenote-timesync-configuration?
            pinenote-timesync-servers
            pinenote-timesync-poll-seconds
            pinenote-timesync-refresh-seconds
            pinenote-timesync-timeout-seconds
            pinenote-timesync-max-backoff-seconds
            pinenote-timesync-not-before
            pinenote-timesync-horizon-seconds
            pinenote-timesync-set-rtc?
            pinenote-timesync-hwclock
            pinenote-timesync-luajit
            pinenote-timesync-script))

;; Set the device clock from SNTP, opportunistically (issue #27).
;;
;; THE PROBLEM.  Nothing on this device sets the clock.  Issue #6 landed
;; the build-time TIMEZONE, and getting the zone right does not help if
;; the underlying time is wrong.  The RTC is the only source, and every
;; method this project reconstructs sessions with is a timestamp: dated
;; doc/status.md entries, the auto-suspend daemon's per-resume charge_now
;; series (the 2026-08-15 soak's entire result is that series divided by
;; its own intervals), the `[pn-refresh]` traces whose analysis is
;; inter-arrival times, and the post-mortem log harvest in
;; doc/device-access.md.  A drifted or reset RTC does not announce
;; itself; it makes all of that read PLAUSIBLY wrong.
;;
;; ---------------------------------------------------------------------
;; THE FIVE SHAPE DECISIONS, and why each went the way it did.  The
;; measurements they rest on are in doc/power-management.md and
;; doc/networking.md; the argument is repeated here because this file is
;; where someone will come to change it.
;;
;; 1. A DAEMON, SHAPED LIKE A ONE-SHOT -- not a boot one-shot, and not an
;;    NTP daemon.
;;
;;    A boot one-shot is far too rare to be useful: measured 2026-08-24,
;;    this device's uptime was 831901 s (9.6 days), so "once per boot" is
;;    "about once a fortnight, if Wi-Fi happened to be up in the first
;;    minute of it".
;;
;;    A one-shot at wpa_supplicant CONNECTED is the shape the issue
;;    proposes, and it is the right INSTINCT -- Wi-Fi dies across ultra
;;    suspend (`vcca_1v8_pmu` feeds VCCIO4; doc/power-management.md), so
;;    the card re-initialises and re-associates on every resume, which
;;    makes association a naturally frequent event.  It does not survive
;;    contact with this image, for two reasons.
;;
;;    First, the only exec hook wpa_supplicant offers is `wpa_cli -a',
;;    which needs a ctrl_interface.  The provisioning recipe in
;;    doc/networking.md §4.1 does set one, so this is not impossible --
;;    but that file is OPERATOR data written out of band onto the data
;;    partition (wifi.scm), it is not ours, and a device provisioned
;;    before that line existed or by hand simply will not have it.  A
;;    clock that works only on correctly-provisioned devices, silently,
;;    is the failure mode this repo keeps writing gates against.
;;
;;    Second, and decisively: CONNECTED fires before DHCP.  Anything
;;    hanging off it has to wait for a route regardless, so "one-shot at
;;    association" collapses into "something that waits for a usable
;;    route" -- which is exactly what this is, minus the dependency on a
;;    file we do not own.
;;
;;    So: a supervised process that sleeps, wakes, looks, and mostly goes
;;    back to sleep.  It does NOT discipline the clock -- no drift file,
;;    no adjtime, no kernel PLL.  At a ~1.5 % awake duty cycle (2026-08-24:
;;    uptime 831901 s against a newest printk timestamp of 12619 s, and
;;    printk stops across suspend) disciplining is meaningless; the thing
;;    being disciplined is asleep 98.5 % of the time and its oscillator
;;    is the RTC's regardless.  It STEPS an unanchored clock and says so.
;;
;; 2. WHICH SERVERS: none, by default.  This is the field with the
;;    default of '(), and the default is the decision.  The reader image
;;    makes no outbound connections at all -- Wi-Fi exists so books and
;;    an SSH session can reach it -- so silently adding a public NTP pool
;;    would change what the device does on someone's network without
;;    anyone choosing it.  Configure a server and it syncs; configure
;;    none and it never opens a socket.
;;
;;    The recommendation, when you do configure one, is an NTP server on
;;    the LAN you already chose to join (a router almost always is one):
;;    an IPv4 literal needs no resolver, so the daemon generates no DNS
;;    traffic either.  `pool.ntp.org' works and is a reasonable choice;
;;    it is simply not one this image will make on your behalf.
;;
;;    Considered and rejected as a default: taking the server from the
;;    DHCP lease (option 42).  It is convenient, and it is exactly the
;;    silent implicit destination this issue exists to avoid -- the
;;    device would talk to whatever host the network it joined nominated,
;;    chosen by nobody.  A future `dhcp-servers?' field could offer it as
;;    an explicit opt-in.
;;
;; 3. NO WI-FI AT ALL -- the common case -- must be free and silent, and
;;    that is a POWER-SAFETY property, not a nicety.  Ultra suspend
;;    measures 5.47 mA idle standby and the hourly RTC backstop alone
;;    accounts for ~0.83 mA of it (doc/artifacts/pinenote-ultra-soak-20260815/),
;;    so a daemon that forced wakes or retried hard would be spending
;;    from a budget a 6.17-day soak had to be run to establish.  The
;;    daemon therefore reads /proc/net/route before it will consider
;;    opening a socket, waits only on poll(NULL, 0, ms) -- a
;;    CLOCK_MONOTONIC timeout, which is not a wakeup source and does not
;;    advance across suspend -- and backs off exponentially when a
;;    configured server does not answer.  With no network a poll costs
;;    two file reads.  With no servers the process exits immediately,
;;    which is why respawn? is #f below.
;;
;; 4. THE RTC BACKSTOP INTERACTION, which is a real foot-gun and is
;;    handled rather than hoped about.  autosuspend.lua arms the backstop
;;    by reading the RTC's OWN clock (/sys/class/rtc/rtc0/since_epoch) and
;;    writing `since_epoch + N' to `wakealarm' -- an absolute value in RTC
;;    seconds.  Two consequences:
;;
;;      * A wrong SYSTEM clock never misplaces the alarm.  The arming
;;        arithmetic never reads the system clock at all, so an unanchored
;;        device still wakes on schedule.  That is worth knowing before
;;        anyone "fixes" the backstop.
;;      * Writing the RTC does.  Step the RTC forward past a pending
;;        alarm and the compare never matches, so that wake silently never
;;        happens; step it backward and the wake is that much later.  What
;;        the backstop MEANS is an interval ("wake within the hour if
;;        nothing else does"), so the daemon preserves the INTERVAL across
;;        its RTC write: read `wakealarm' and `since_epoch' before, write
;;        the RTC, then re-arm at the new `since_epoch' plus the remaining
;;        time.  `rearm_alarm_value' in timesync.lua is that arithmetic and
;;        the host suite pins it.
;;
;;      RESIDUAL, stated rather than papered over: the two daemons do not
;;      lock against each other, so a sync that lands inside the <=10 s
;;      window between arm_backstop() and the /sys/power/state write in
;;      suspend_once() can still leave that ONE cycle without a working
;;      alarm.  Every subsequent suspend re-arms from scratch, so it
;;      self-heals at the next cycle, and the primary wake (the power
;;      button) is hardware-proven.  Set set-rtc? #f if you would rather
;;      not carry even that.
;;
;; 5. WRITE BACK TO THE RTC: yes, default #t.  Without it the correction
;;    dies at the next cold boot and a device that syncs once and then
;;    never sees Wi-Fi again -- entirely plausible for a reader -- keeps
;;    nothing.  hwclock(8) does the write, with --noadjfile because there
;;    is no drift model here to maintain, and --utc because that is what
;;    Guix and the kernel assume.
;;
;; ---------------------------------------------------------------------
;; WHAT THIS IS NOT.  SNTP is unauthenticated: whoever can answer on the
;; path can set this clock, within the sanity window below.  That is the
;; protocol, not an oversight, and it is why the window exists and why
;; the default server list is empty.  Nothing on the reader makes a
;; security decision on the clock today (SSH is key-only and time-blind),
;; but do not build one on this without saying so first.
;;
;; NOTHING HERE HAS BEEN BOOTED.  The daemon is host-tested end to end
;; over loopback (`make timesync-check') and the service evaluates, but
;; no clock has been set on a PineNote and no image carrying it has run.

;; Resolved HERE, at this module's top level, and deliberately not inline
;; in the record default below.  `define-record-type*' expands a field
;; default at the CONSTRUCTOR CALL SITE, and `local-file' with a relative
;; path resolves against the source file it is expanded in -- so an inline
;; default would look for ../tools/timesync/ relative to whatever file
;; happened to write (pinenote-timesync-configuration ...), and fail with a
;; canonicalize-path error for anyone configuring this from outside
;; pinenote/systems/.  Binding it once here makes the default a plain
;; variable reference and the path unambiguous.
(define %pinenote-timesync-script
  (local-file "../tools/timesync/timesync.lua"))

(define-record-type* <pinenote-timesync-configuration>
  pinenote-timesync-configuration make-pinenote-timesync-configuration
  pinenote-timesync-configuration?
  ;; A list of "HOST" or "HOST:PORT" strings, tried in order until one
  ;; answers plausibly.  EMPTY IS THE SHIPPED DEFAULT -- see decision 2
  ;; above; with no servers the daemon opens no socket and exits.
  (servers               pinenote-timesync-servers               (default '()))
  ;; AWAKE seconds between checks: the wait is monotonic, so it does not
  ;; run down while the device is suspended.  At the measured ~1.5 % duty
  ;; cycle 120 s is roughly one check every two hours of wall time, and
  ;; several per session in which the device is actually being read --
  ;; which is exactly when a network is likely to be there.
  (poll-seconds          pinenote-timesync-poll-seconds          (default 120))
  ;; WALL seconds between successful syncs.  6 h is not a drift estimate;
  ;; it is "often enough that a session's timestamps are anchored, rarely
  ;; enough that it is one UDP exchange per reading session".
  (refresh-seconds       pinenote-timesync-refresh-seconds       (default 21600))
  (timeout-seconds       pinenote-timesync-timeout-seconds       (default 5))
  ;; Cap for the exponential failure backoff.  This is the number that
  ;; makes an unreachable server cost less over time instead of more.
  (max-backoff-seconds   pinenote-timesync-max-backoff-seconds   (default 3600))
  ;; Sanity FLOOR, 2026-01-01T00:00:00Z.  Not authentication -- it only
  ;; rejects answers that are obviously junk, the 1970 of a reset RTC
  ;; being the one that actually happens.  A constant rather than the
  ;; build date, because stamping the build date into a default would
  ;; make the derivation unreproducible; it therefore ages, and this
  ;; field is how you move it.
  (not-before            pinenote-timesync-not-before            (default 1767225600))
  ;; ... and the ceiling, as a span above the floor: 20 years.
  (horizon-seconds       pinenote-timesync-horizon-seconds       (default 630720000))
  ;; Write the corrected time back to the RTC (decision 5).
  (set-rtc?              pinenote-timesync-set-rtc?              (default #t))
  ;; An ABSOLUTE path, not a PATH lookup: shepherd services start with an
  ;; essentially empty environment on this device (wifi.scm:26-28,
  ;; library.scm), and a silent failure branch here would mean the RTC
  ;; quietly never gets written while every gate stayed green.
  (hwclock               pinenote-timesync-hwclock
                         (default (file-append util-linux "/sbin/hwclock")))
  ;; The bundle's own luajit -- the same interpreter reader-session and
  ;; the auto-suspend daemon run, and the only one on the image with the
  ;; ffi this needs.
  (luajit                pinenote-timesync-luajit
                         (default (file-append koreader-bin "/lib/koreader/luajit")))
  (script                pinenote-timesync-script
                         (default %pinenote-timesync-script)))

(define (pinenote-timesync-shepherd-service config)
  (let ((servers  (pinenote-timesync-servers config))
        (poll     (pinenote-timesync-poll-seconds config))
        (refresh  (pinenote-timesync-refresh-seconds config))
        (timeout  (pinenote-timesync-timeout-seconds config))
        (backoff  (pinenote-timesync-max-backoff-seconds config))
        (earliest (pinenote-timesync-not-before config))
        (horizon  (pinenote-timesync-horizon-seconds config))
        (set-rtc? (pinenote-timesync-set-rtc? config))
        (hwclock  (pinenote-timesync-hwclock config))
        (luajit   (pinenote-timesync-luajit config))
        (script   (pinenote-timesync-script config)))
    (list
     (shepherd-service
      (provision '(pinenote-timesync))
      ;; Deliberately only user-processes.  Requiring `networking' would
      ;; couple the clock to dhcpcd starting successfully, and requiring
      ;; `pinenote-wifi' would make this service unusable on a flavor that
      ;; has no Wi-Fi service at all.  The daemon's own /proc/net/route
      ;; check is the real gate, and it re-checks forever, so ordering
      ;; buys nothing that waiting does not.
      (requirement '(user-processes))
      (documentation "Step the system clock from SNTP whenever a network is present; no-op when no server is configured.")
      (start
       #~(make-forkexec-constructor
          (list #$luajit #$script
                "--poll" #$(number->string poll)
                "--refresh" #$(number->string refresh)
                "--timeout" #$(number->string timeout)
                "--max-backoff" #$(number->string backoff)
                "--not-before" #$(number->string earliest)
                "--horizon" #$(number->string horizon)
                "--hwclock" #$(if set-rtc? hwclock "")
                #$@(append-map (lambda (server) (list "--server" server))
                               servers))
          #:log-file "/var/log/pinenote-timesync.log"))
      (stop #~(make-kill-destructor))
      ;; NOT respawned, and that is the point of decision 3.  With no
      ;; servers configured -- the shipped default -- the daemon logs one
      ;; line and exits 0; respawning it would turn the deliberately
      ;; inert default into a restart loop.  It also means a crash stays
      ;; dead until the next boot, which for a best-effort clock setter
      ;; is the safe direction: a crash-looping time client is strictly
      ;; worse than no time client.
      (respawn? #f)))))

(define pinenote-timesync-service-type
  (service-type
   (name 'pinenote-timesync)
   (extensions
    (list (service-extension shepherd-root-service-type
                             pinenote-timesync-shepherd-service)))
   (default-value (pinenote-timesync-configuration))
   (description "Step the PineNote's clock from SNTP when a network happens to be
present, and write the correction back to the RTC.  Opt-in: with no servers
configured it makes no outbound connection at all.")))
