(define-module (pinenote images pinenote-partitions)
  #:export (pinenote-root-label
            pinenote-state-label
            pinenote-waveform-partlabel
            pinenote-root-partition-description))

(define pinenote-root-label "PNGuixRoot")
(define pinenote-state-label "PNGuixState")
(define pinenote-waveform-partlabel "waveform")

(define pinenote-root-partition-description
  '((label . "PNGuixRoot")
    (kind . ext4-root-file-system)
    (intended-use . "manual placement into a preselected experimental OS slot")
    (destructive-automation . #f)))
