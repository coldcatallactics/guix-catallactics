;;; xenolith.scm --- the Xenolith Autolith site configuration and launcher.
;;;
;;; Xenolith is not a fork of Autolith: it is a curated site layer that
;;; Autolith loads when AUTOLITH_SITE_CONFIG_ROOT points at it.  Upstream
;;; ships the tree under site/ and generates the launcher in its Nix flake;
;;; this package does the same for Guix: install the site tree under
;;; share/xenolith/site and a bin/xenolith wrapper that exports the variable
;;; and execs the channel's autolith-bin.
;;;
;;; The package deliberately imports (catallactics autolith) rather than
;;; carrying its own Autolith.  There is no cycle: autolith-bin does not
;;; import xenolith, and the wrapper's reference to its /bin/autolith is what
;;; makes it a runtime dependency.

(define-module (catallactics xenolith)
  #:use-module (catallactics autolith)
  #:use-module (gnu packages bash)
  #:use-module (guix build-system gnu)
  #:use-module (guix gexp)
  #:use-module (guix git-download)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (guix packages)
  #:export (xenolith))

(define %xenolith-commit
  "68485a48ac156af1ab252e12aa18a04080940a91")

(define-public xenolith
  (package
    (name "xenolith")
    ;; The site tree reports 0.2.0; there are no upstream tags, so the
    ;; snapshot suffix records the exact commit.
    (version (git-version "0.2.0" "1" %xenolith-commit))
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/coldcatallactics/xenolith")
             (commit %xenolith-commit)))
       (file-name (git-file-name name version))
       (sha256
        (base32 "048wcak5im8x0ksx9dswxazqzn9jjh8gd3jjlxbl03d7xfj4sgmw"))))
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (delete 'build)
          (replace 'install
            (lambda _
              (let* ((out #$output)
                     (site (string-append out "/share/xenolith/site"))
                     (bin (string-append out "/bin/xenolith")))
                (mkdir-p site)
                (copy-recursively (string-append #$source "/site") site)
                (install-file (string-append #$source "/LICENSE")
                              (string-append out "/share/licenses/xenolith"))
                (mkdir-p (string-append out "/bin"))
                (call-with-output-file bin
                  (lambda (port)
                    (format port "#!~a~%"
                            #$(file-append bash-minimal "/bin/bash"))
                    (format port
                     "# Xenolith launcher: run Autolith with this site tree.~%")
                    (format port "export AUTOLITH_SITE_CONFIG_ROOT=\"~a\"~%"
                            site)
                    (format port "exec ~a \"$@\"~%"
                            #$(file-append autolith-bin "/bin/autolith"))))
                (chmod bin #o555)))))))
    (inputs (list autolith-bin bash-minimal))
    (supported-systems '("x86_64-linux"))
    (synopsis "Opinionated Autolith site configuration")
    (description
     "Xenolith is a curated configuration layer for the Autolith terminal
agent: presentation, defaults, and commands supplied as an Autolith site
tree.  This package installs the site tree and a @command{xenolith} launcher
that points @env{AUTOLITH_SITE_CONFIG_ROOT} at it before starting the
channel's @command{autolith-bin}.")
    (home-page "https://github.com/coldcatallactics/xenolith")
    (license license:isc)))
