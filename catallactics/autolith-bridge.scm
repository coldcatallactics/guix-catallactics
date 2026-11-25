;;; autolith-bridge.scm --- not packaged yet: see docs/autolith-bridge.org.
;;;
;;; autolith-remote (https://github.com/chakanysystems/autolith-remote) is an
;;; Apache-2.0 Swift package.  The Linux product is the `autolith-bridge'
;;; executable from the AutolithBridge target; the iOS app in the same
;;; repository is not a Guix target.
;;;
;;; This module intentionally defines no package.  Guix's `swift' 6.2 package
;;; is compiler-only: it ships swiftc and the core standard library, but no
;;; Foundation, FoundationNetworking, Dispatch Swift module, _Concurrency,
;;; XCTest, swift-driver or SwiftPM.  The bridge imports Foundation throughout
;;; and uses async/await, so any package definition would fail at the first
;;; compile or `swift build' invocation.  The channel ships without
;;; autolith-bridge until that toolchain gap is closed; the evidence and the
;;; exact requirements are in docs/autolith-bridge.org.
;;;
;;; Do not replace this with a placeholder package or a Nix wrapper: the
;;; channel carries public Guix packages only, and a package that cannot
;;; build is worse than an honest absence.

(define-module (catallactics autolith-bridge)
  #:export (autolith-bridge-blocker))

(define autolith-bridge-blocker
  "Guix's swift 6.2 package lacks Foundation, the Dispatch Swift module,
_Concurrency, XCTest, swift-driver and SwiftPM; autolith-bridge needs them.
See docs/autolith-bridge.org.")
