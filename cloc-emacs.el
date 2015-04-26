;;; cloc-emacs.el --- count lines of code over emacs buffers

;;; Copyright 2015 Danny McClanahan

;;; Author: Danny McClanahan <danieldmcclanahan@gmail.com>
;;; Version: 2015.04.26
;;; Package-Version: 0.0.0
;;; URL:

;;; this file is not part of GNU Emacs

(defcustom cloc-use-3rd-gen t
  "Whether or not to use cloc's third-generation language output option.")

(defun cloc-get-output (prefix-given be-quiet &optional regex)
  "Helper function to get cloc output for a given set of buffers based on regex,
or the current buffer, as desired. If used programmatically, be aware that it
will query for a regex if one is not provided by argument."
  (if (executable-find "cloc")
      (let
          ((result
            (catch 'invalid-regexp
              (let ((buffers-to-cloc (list (buffer-file-name))))
                ;; if prefix given, cloc current buffer; don't ask for regex
                (unless prefix-given
                  (setq
                   buffers-to-cloc
                   (let ((regex-str
                          (or regex
                              (read-from-minibuffer "file path regex: "))))
                     ;; if blank string given, then assume the current file name
                     ;; was what was intended.
                     (if (string= regex-str "")
                         (list (buffer-file-name))
                       (loop for buf in (buffer-list)
                             with ret-list = nil
                             do (let ((name (buffer-file-name buf)))
                                  (when (and name
                                             (string-match-p regex-str name))
                                    (add-to-list 'ret-list name)))
                             finally (return ret-list))))))
                ;; return list so we can tell the difference between an invalid
                ;; regexp versus a real result, even though the list always has
                ;; only one element
                (list
                 (if buffers-to-cloc
                     (shell-command-to-string
                      (apply #'concat
                             (cons (let ((base
                                          (if be-quiet
                                              "cloc --quiet --csv "
                                            "cloc ")))
                                     (if cloc-use-3rd-gen
                                         (concat base "--3 ")
                                       base))
                                   (mapcar (lambda (str) (concat str " "))
                                           buffers-to-cloc))))
                   "No filenames were found matching regex."))))))
        (if (stringp result)
            (concat "regex invalid: " result)
          ;; unlistify the result
          (car result)))
    "cloc not installed. Download it at http://cloc.sourceforge.net/."))

(defun cloc-get-lines-of-str-as-list (str)
  "Gets and returns lines of string (without ending newline) into a list."
  ;; will add a newline to the end of str if not already there, but removes it
  ;; at bottom
  ;; 10 is newline
  (let ((is-final-char-newline (char-equal (aref str (1- (length str))) 10)))
    (unless is-final-char-newline
      (setq str (concat str "\n")))
    (with-temp-buffer
      (insert str)
      (goto-char (point-min))
      (let ((line-list nil))
        (setq line-list
              (cons
               (buffer-substring-no-properties
                (line-beginning-position) (line-end-position))
               nil))
        (setq line-list
              (append line-list
                      (loop while (= 0 (forward-line 1))
                            collect (buffer-substring-no-properties
                                     (line-beginning-position)
                                     (line-end-position)))))
        (if is-final-char-newline
            line-list
          (get-first-n-of-list (1- (length line-list)) line-list))))))

(defun cloc-get-line-as-plist (line)
  "Helper function to convert a CSV-formatted line of cloc output into a plist
representing a cloc analysis."
  (let ((out-plist nil))
    (loop for str-pos from 0 upto (1- (length line))
          with prev-str-pos = 0
          with cur-prop = :files
          while (or cloc-use-3rd-gen
                    (not (eq cur-prop :scale)))
          do (progn
               (when (char-equal (aref line str-pos) 44) ;  44 is comma
                 (cond ((eq cur-prop :files)
                        (setq out-plist
                              (plist-put out-plist :files
                                         (string-to-number
                                          (substring line prev-str-pos
                                                     str-pos))))
                        (setq cur-prop :language))
                       ((eq cur-prop :language)
                        (setq out-plist
                              (plist-put out-plist :language
                                         (substring line prev-str-pos
                                                    str-pos)))
                        (setq cur-prop :blank))
                       ((eq cur-prop :blank)
                        (setq out-plist
                              (plist-put out-plist :blank
                                         (string-to-number
                                          (substring line prev-str-pos
                                                     str-pos))))
                        (setq cur-prop :comment))
                       ((eq cur-prop :comment)
                        (setq out-plist
                              (plist-put out-plist :comment
                                         (string-to-number
                                          (substring line prev-str-pos
                                                     str-pos))))
                        (setq cur-prop :code))
                       ((eq cur-prop :code)
                        (setq out-plist
                              (plist-put out-plist :code
                                         (string-to-number
                                          (substring line prev-str-pos
                                                     str-pos))))
                        (setq cur-prop :scale))
                       ((eq cur-prop :scale)
                        (setq out-plist
                              (plist-put out-plist :scale
                                         (string-to-number
                                          (substring line prev-str-pos
                                                     str-pos))))
                        (setq cur-prop :3rd-gen-equiv))
                       (t
                        (throw
                         'invalid-property
                         "cur-prop should never be here! This is a bug.")))
                 (setq prev-str-pos (1+ str-pos))))
          finally (cond ((eq cur-prop :3rd-gen-equiv)
                         (setq out-plist
                               (plist-put out-plist :3rd-gen-equiv
                                          (string-to-number
                                           (substring line prev-str-pos
                                                      str-pos)))))
                        ((eq cur-prop :code)
                         (setq out-plist
                               (plist-put out-plist :code
                                          (string-to-number
                                           (substring line prev-str-pos
                                                      str-pos)))))))
    out-plist))

(defun cloc-get-results-as-plists (prefix-given regex)
  "Get output of cloc results as a list of plists. Each plist contains as a
property the number of files analyzed, the blank lines, the code lines, comment
lines, etc. for a given language in the range of files tested. If prefix-given
is set to true, this runs on the current buffer. If not, and a regex is given,
it will search file-visiting buffers for file paths matching the regex. If the
regex is nil, it will prompt for a regex; putting in a blank there will default
to the current buffer."
  ;; cdr called here because first line is blank
  (remove-if #'not                      ; remove nils which sometimes appear fsr
             (mapcar
              #'cloc-get-line-as-plist
              ;; first two lines are blank line and csv header, so discard
              (nthcdr 2 (cloc-get-lines-of-str-as-list
                         (cloc-get-output prefix-given t regex))))))

(defun cloc (prefix-given)
  "Run the executable \"cloc\" over file-visiting buffers with pathname
specified by a regex. If prefix argument or a blank regex is given, the
current buffer is \"cloc'd\". cloc's entire summary output is given in the
messages buffer."
  (interactive "P")
  (message (cloc-get-output prefix-given nil)))

(provide 'cloc-emacs)