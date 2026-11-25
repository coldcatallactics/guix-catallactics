;;; opencode.scm --- the opencode CLI from the upstream release binary.
;;;
;;; opencode is a Bun-compiled TypeScript application.  There is no Bun in
;;; Guix and no practical source build for the bundled npm tree, so this is
;;; the hash-pinned upstream Linux binary.  The interpreter is patched to
;;; Guix's loader (the binary expects /lib64, which Guix does not provide);
;;; the binary otherwise needs only the C library and is installed directly.

(define-module (catallactics opencode)
  #:use-module (gnu packages base)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages elf)
  #:use-module (guix build-system trivial)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (guix packages)
  #:export (opencode-bin))

(define-public opencode-bin
  (package
    (name "opencode-bin")
    (version "2.4.1")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/anomalyco/opencode/releases/download/v"
             version "/opencode-linux-x64.tar.gz"))
       (sha256
        (base32 "0iwb8x7qj7g5bcgbdmazmqh4b8f7lnbbrz50yv6awkpnzbiiipcx"))))
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (let* ((out #$output)
                 (bin (string-append out "/bin"))
                 (src (assoc-ref %build-inputs "source"))
                 (patchelf (assoc-ref %build-inputs "patchelf"))
                 (tar (assoc-ref %build-inputs "tar"))
                 (gzip (assoc-ref %build-inputs "gzip"))
                 (glibc (assoc-ref %build-inputs "glibc")))
            (mkdir-p bin)
            (setenv "PATH"
                    (string-append tar "/bin:" gzip "/bin:"
                                   (getenv "PATH")))
            (invoke "tar" "xzf" src)
            (copy-file "opencode"
                       (string-append bin "/opencode"))
            (invoke (string-append patchelf "/bin/patchelf")
                    "--set-interpreter"
                    (string-append glibc "/lib/ld-linux-x86-64.so.2")
                    (string-append bin "/opencode"))
            (chmod (string-append bin "/opencode") #o555)))))
    (native-inputs (list patchelf tar gzip))
    (inputs (list glibc))
    (supported-systems '("x86_64-linux"))
    (synopsis "Terminal AI coding agent")
    (description
     "opencode is a terminal-based AI coding agent.  This package installs the
upstream Linux release binary.")
    (home-page "https://github.com/anomalyco/opencode")
    (license license:expat)))
