;;; autolith.scm --- the Autolith release for x86-64 Linux.
;;;
;;; Autolith is a self-modifiable Common Lisp agent built on SBCL.  A source
;;; build is not practical here: it needs a large SBCL/Quicklisp closure, a
;;; pinned SBCL source tree and native dependencies assembled by its own
;;; build scripts.  This package installs the hash-pinned upstream binary
;;; release, which already contains the SBCL runtime, the Quicklisp tree and
;;; the native search and syntax libraries.
;;;
;;; The release archive has this layout (493 MiB unpacked):
;;;
;;;   bin/autolith                          bash release launcher
;;;   lib/libfff_c.so                       search helper (zlib, libgcc_s)
;;;   lib/libcolorlisp-tree-sitter.so       syntax helper
;;;   libexec/autolith/                     source tree, .git and .qlot deps
;;;   libexec/sbcl-source/                  SBCL source for the runtime
;;;   libexec/cl-exec-sandbox-*             sandbox helpers
;;;   runtime/bin/sbcl, runtime/lib/sbcl/   bundled SBCL and core
;;;
;;; The release launcher builds its private active/recovery images on first
;;; start under $XDG_DATA_HOME/autolith, so the store tree itself stays
;;; read-only.  The wrapper only supplies the external commands the launcher
;;; and the agent expect (git, bwrap, ldd, sed, ...), and disables the
;;; upstream self-updater: a Guix package owns its version.
;;;
;;; Every ELF file is patched to Guix's loader.  The two native libraries get
;;; a RUNPATH for glibc, zlib and libgcc_s; the executables get the loader.
;;; The qlot tree ships copies of the sandbox helpers, which are patched too.

(define-module (catallactics autolith)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages curl)
  #:use-module (gnu packages elf)
  #:use-module (gnu packages gawk)
  #:use-module (gnu packages gcc)
  #:use-module (gnu packages tls)
  #:use-module (gnu packages version-control)
  #:use-module (gnu packages virtualization)
  #:use-module (guix build-system trivial)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module ((guix licenses)
                #:prefix license:)
  #:use-module (guix packages)
  #:export (autolith-bin))

(define-public autolith-bin
  (package
    (name "autolith-bin")
    (version "0.69.3")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/lambda-symbolics/autolith/releases/download/v"
             version "/autolith-v" version "-x86_64-linux.tar.gz"))
       (file-name (string-append "autolith-v" version "-x86_64-linux.tar.gz"))
       (sha256
        (base32 "0q10k3wbqb9v259hk4d42ry7cqaclyxm3nqfwghncd7m9gc3cq3h"))))
    (build-system trivial-build-system)
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))

          (let* ((out #$output)
                 (src (assoc-ref %build-inputs "source"))
                 (patchelf (string-append (assoc-ref %build-inputs "patchelf")
                                          "/bin/patchelf"))
                 (tar (assoc-ref %build-inputs "tar"))
                 (gzip (assoc-ref %build-inputs "gzip"))
                 (glibc (assoc-ref %build-inputs "glibc"))
                 (gcc-lib (assoc-ref %build-inputs "gcc"))
                 (zlib (assoc-ref %build-inputs "zlib"))
                 (work (getcwd))
                 (release "autolith-v0.69.3-x86_64-linux")
                 (tree (string-append out "/libexec/autolith"))
                 (bin (string-append out "/bin"))
                 (loader (string-append glibc "/lib/ld-linux-x86-64.so.2"))
                 (rpath (string-join (list (string-append glibc "/lib")
                                           (string-append zlib "/lib")
                                           (string-append gcc-lib "/lib")) ":"))
                 (runtime-programs '("bash-minimal" "coreutils-minimal"
                                     "findutils"
                                     "grep"
                                     "sed"
                                     "gawk"
                                     "git"
                                     "bubblewrap"
                                     "glibc"
                                     "curl"
                                     "openssl"
                                     "tar"
                                     "gzip"
                                     "xz"))
                 (runtime-path (string-join (map (lambda (name)
                                                   (string-append (assoc-ref
                                                                   %build-inputs
                                                                   name)
                                                                  "/bin"))
                                                 runtime-programs) ":")))
            (setenv "PATH"
                    (string-append tar "/bin:" gzip "/bin:"
                                   (getenv "PATH")))
            (invoke "tar" "xzf" src)

            (mkdir-p (dirname tree))
            (copy-recursively (string-append work "/" release)
                              tree
                              #:keep-mtime? #t
                              #:log #f)

            ;; The release scripts use `#!/usr/bin/env ...'.  Guix System does
            ;; not guarantee /usr/bin/env, so resolve every text shebang
            ;; against the packaged bash before the ELF patch below.
            (for-each (lambda (file)
                        (false-if-exception (patch-shebang file
                                                           (list (string-append
                                                                  (assoc-ref
                                                                   %build-inputs
                                                                   "bash")
                                                                  "/bin")))))
                      (find-files tree))

            ;; The release's native libraries carry the usual /lib64
            ;; interpreter and no RUNPATH.  The shared libraries get a
            ;; RUNPATH for glibc, zlib and libgcc_s; the executables get
            ;; Guix's loader.  The tarball ships read-only files, so make each
            ;; one writable while patchelf runs.
            (for-each (lambda (file)
                        (when (elf-file? file)
                          (let ((executable? (executable-file? file)))
                            (chmod file #o755)
                            (if executable?
                                (invoke patchelf "--set-interpreter" loader
                                        file)
                                (invoke patchelf "--set-rpath" rpath file))
                            (chmod file
                                   (if executable? 365 292)))))
                      (find-files tree))

            (mkdir-p bin)
            (let ((wrapper (string-append bin "/autolith")))
              (call-with-output-file wrapper
                (lambda (port)
                  (format port "#!~a\n"
                          #$(file-append bash-minimal "/bin/bash"))
                  (format port "set -euo pipefail\n")
                  (format port "export PATH=\"~a${PATH:+:$PATH}\"\n"
                          runtime-path)
                  ;; cl+ssl loads libcrypto/libssl with dlopen, so the
                  ;; OpenSSL library directory must be on the loader path.
                  (format port
                          (string-append "export LD_LIBRARY_PATH=\"~a"
                           "${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\"\n")
                          #$(file-append openssl "/lib"))
                  ;; A Guix package owns its version; the release tree is not
                  ;; in the layout the upstream updater expects anyway.
                  (format port
                          (string-append "export AUTOLITH_NO_UPDATE_CHECK=\""
                                         "${AUTOLITH_NO_UPDATE_CHECK:-1}\"\n"))
                  (format port
                          (string-append
                           "export AUTOLITH_SUPPRESS_UPDATE_OFFER=\""
                           "${AUTOLITH_SUPPRESS_UPDATE_OFFER:-1}\"\n"))
                  (format port "exec ~a \"$@\"\n"
                          (string-append tree "/bin/autolith"))))
              (chmod wrapper #o555))))))
    (native-inputs (list patchelf tar gzip))
    (inputs (list bash-minimal
                  bubblewrap
                  coreutils-minimal
                  curl
                  findutils
                  gawk
                  ;; The lib output supplies libgcc_s for libfff_c.so.
                  (list gcc "lib")
                  git
                  glibc
                  grep
                  openssl
                  sed
                  tar
                  gzip
                  xz
                  zlib))
    (supported-systems '("x86_64-linux"))
    (synopsis "Self-modifiable Common Lisp AI agent")
    (description
     "Autolith is a self-modifiable Common Lisp AI agent that runs in the
terminal.  This package installs the upstream Linux release, including its
bundled SBCL runtime and Lisp dependency tree.  No language models or provider
credentials are bundled; models are selected through the agent's own
configuration.")
    (home-page "https://github.com/lambda-symbolics/autolith")
    (license license:isc)))
