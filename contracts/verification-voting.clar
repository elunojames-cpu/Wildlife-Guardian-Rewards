;; Verification Voting Smart Contract
;; Handles verifier staking, voting on sighting authenticity, and slashing/reward logic.
;; Integrates with sighting-submission contract to update statuses.

;; Constants
(define-constant ERR-UNAUTHORIZED u200)
(define-constant ERR-INVALID-SIGHTING u201)
(define-constant ERR-ALREADY-VOTED u202)
(define-constant ERR-NOT-STAKED u203)
(define-constant ERR-VOTING-CLOSED u204)
(define-constant ERR-INVALID-VOTE u205)
(define-constant ERR-INSUFFICIENT-STAKE u206)
(define-constant ERR-PAUSED u207)
(define-constant ERR-INVALID-AMOUNT u208)
(define-constant ERR-INTEGRATION-FAILURE u209)
(define-constant MIN-STAKE-AMOUNT u1000)
(define-constant VOTING_PERIOD u144) ;; ~1 day in blocks
(define-constant MAJORITY-THRESHOLD u66) ;; 66% for consensus
(define-constant SLASH-PERCENT u10) ;; 10% stake slashing for wrong votes
(define-constant REWARD-PERCENT u5) ;; 5% of stake as reward for correct votes

;; Data Variables
(define-data-var admin principal tx-sender)
(define-data-var paused bool false)
(define-data-var token-contract principal tx-sender)
(define-data-var submission-contract principal tx-sender)

;; Data Maps
(define-map verifiers
  { verifier: principal }
  {
    stake-amount: uint,
    active: bool,
    last-voted: uint
  }
)

(define-map votes
  { sighting-id: uint, verifier: principal }
  {
    vote: bool, ;; true for valid, false for invalid
    timestamp: uint
  }
)

(define-map voting-status
  { sighting-id: uint }
  {
    start-block: uint,
    yes-votes: uint,
    no-votes: uint,
    total-voters: uint,
    closed: bool,
    outcome: (optional bool)
  }
)

;; Private Functions
(define-private (is-verifier-active (verifier principal))
  (let
    (
      (verifier-data (default-to { stake-amount: u0, active: false, last-voted: u0 } (map-get? verifiers { verifier: verifier })))
    )
    (and (get active verifier-data) (>= (get stake-amount verifier-data) MIN-STAKE-AMOUNT))
  )
)

(define-private (transfer-tokens (amount uint) (from principal) (to principal))
  (contract-call? (var-get token-contract) transfer amount from to)
)

(define-private (slash-stake (verifier principal) (amount uint))
  (let
    (
      (verifier-data (unwrap! (map-get? verifiers { verifier: verifier }) (err ERR-NOT-STAKED)))
      (slash-amount (/ (* (get stake-amount verifier-data) SLASH-PERCENT) u100))
    )
    (try! (transfer-tokens slash-amount verifier tx-sender)) ;; Burn or send to admin
    (map-set verifiers { verifier: verifier }
      (merge verifier-data { stake-amount: (- (get stake-amount verifier-data) slash-amount) }))
    (ok true)
  )
)

(define-private (reward-verifier (verifier principal) (amount uint))
  (let
    (
      (verifier-data (unwrap! (map-get? verifiers { verifier: verifier }) (err ERR-NOT-STAKED)))
      (reward-amount (/ (* (get stake-amount verifier-data) REWARD-PERCENT) u100))
    )
    (try! (transfer-tokens reward-amount tx-sender verifier))
    (ok true)
  )
)

(define-private (update-sighting-status (sighting-id uint) (outcome bool))
  (contract-call? (var-get submission-contract) update-sighting-status sighting-id (if outcome u"verified" u"rejected"))
)

;; Public Functions
(define-public (stake-tokens (amount uint))
  (let
    (
      (verifier-data (default-to { stake-amount: u0, active: false, last-voted: u0 } (map-get? verifiers { verifier: tx-sender })))
    )
    (asserts! (not (var-get paused)) (err ERR-PAUSED))
    (asserts! (>= amount MIN-STAKE-AMOUNT) (err ERR-INSUFFICIENT-STAKE))
    (try! (transfer-tokens amount tx-sender (as-contract tx-sender)))
    (map-set verifiers { verifier: tx-sender }
      {
        stake-amount: (+ (get stake-amount verifier-data) amount),
        active: true,
        last-voted: (get last-voted verifier-data)
      }
    )
    (ok true)
  )
)

(define-public (unstake-tokens (amount uint))
  (let
    (
      (verifier-data (unwrap! (map-get? verifiers { verifier: tx-sender }) (err ERR-NOT-STAKED)))
      (current-stake (get stake-amount verifier-data))
    )
    (asserts! (not (var-get paused)) (err ERR-PAUSED))
    (asserts! (> amount u0) (err ERR-INVALID-AMOUNT))
    (asserts! (<= amount current-stake) (err ERR-INSUFFICIENT-STAKE))
    (asserts! (> (- block-height (get last-voted verifier-data)) VOTING_PERIOD) (err ERR-UNAUTHORIZED))
    (try! (as-contract (transfer-tokens amount tx-sender tx-sender)))
    (map-set verifiers { verifier: tx-sender }
      {
        stake-amount: (- current-stake amount),
        active: (>= (- current-stake amount) MIN-STAKE-AMOUNT),
        last-voted: (get last-voted verifier-data)
      }
    )
    (ok true)
  )
)

(define-public (vote-on-sighting (sighting-id uint) (vote bool))
  (let
    (
      (voting-data (unwrap! (map-get? voting-status { sighting-id: sighting-id }) (err ERR-INVALID-SIGHTING)))
      (verifier-data (unwrap! (map-get? verifiers { verifier: tx-sender }) (err ERR-NOT-STAKED)))
    )
    (asserts! (not (var-get paused)) (err ERR-PAUSED))
    (asserts! (is-verifier-active tx-sender) (err ERR-NOT-STAKED))
    (asserts! (is-none (map-get? votes { sighting-id: sighting-id, verifier: tx-sender })) (err ERR-ALREADY-VOTED))
    (asserts! (not (get closed voting-data)) (err ERR-VOTING-CLOSED))
    (asserts! (<= (- block-height (get start-block voting-data)) VOTING_PERIOD) (err ERR-VOTING-CLOSED))
    (map-set votes { sighting-id: sighting-id, verifier: tx-sender }
      { vote: vote, timestamp: block-height })
    (map-set verifiers { verifier: tx-sender }
      (merge verifier-data { last-voted: block-height }))
    (map-set voting-status { sighting-id: sighting-id }
      (merge voting-data
        {
          yes-votes: (if vote (+ (get yes-votes voting-data) u1) (get yes-votes voting-data)),
          no-votes: (if (not vote) (+ (get no-votes voting-data) u1) (get no-votes voting-data)),
          total-voters: (+ (get total-voters voting-data) u1)
        }
      )
    )
    (try! (check-voting-outcome sighting-id))
    (ok true)
  )
)

(define-public (initiate-verification (sighting-id uint))
  (begin
    (asserts! (is-eq tx-sender (var-get submission-contract)) (err ERR-UNAUTHORIZED))
    (asserts! (is-none (map-get? voting-status { sighting-id: sighting-id })) (err ERR-ALREADY-SUBMITTED))
    (map-set voting-status { sighting-id: sighting-id }
      {
        start-block: block-height,
        yes-votes: u0,
        no-votes: u0,
        total-voters: u0,
        closed: false,
        outcome: none
      }
    )
    (ok true)
  )
)

(define-public (pause-contract)
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR-UNAUTHORIZED))
    (var-set paused true)
    (ok true)
  )
)

(define-public (unpause-contract)
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR-UNAUTHORIZED))
    (var-set paused false)
    (ok true)
  )
)

(define-public (set-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR-UNAUTHORIZED))
    (var-set admin new-admin)
    (ok true)
  )
)

(define-public (set-token-contract (new-contract principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR-UNAUTHORIZED))
    (var-set token-contract new-contract)
    (ok true)
  )
)

(define-public (set-submission-contract (new-contract principal))
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR-UNAUTHORIZED))
    (var-set submission-contract new-contract)
    (ok true)
  )
)

;; Private Function to Check Voting Outcome
(define-private (check-voting-outcome (sighting-id uint))
  (let
    (
      (voting-data (unwrap! (map-get? voting-status { sighting-id: sighting-id }) (err ERR-INVALID-SIGHTING)))
      (total-votes (get total-voters voting-data))
      (yes-votes (get yes-votes voting-data))
      (no-votes (get no-votes voting-data))
      (percent-yes (if (> total-votes u0) (/ (* yes-votes u100) total-votes) u0))
    )
    (if (or (>= percent-yes MAJORITY-THRESHOLD) (<= (- block-height (get start-block voting-data)) VOTING_PERIOD))
      (begin
        (map-set voting-status { sighting-id: sighting-id }
          (merge voting-data { closed: true, outcome: (some (>= percent-yes MAJORITY-THRESHOLD)) }))
        (try! (update-sighting-status sighting-id (>= percent-yes MAJORITY-THRESHOLD)))
        (try! (process-vote-results sighting-id (>= percent-yes MAJORITY-THRESHOLD)))
        (ok true)
      )
      (ok false)
    )
  )
)

(define-private (process-vote-results (sighting-id uint) (outcome bool))
  (let
    (
      (voting-data (unwrap! (map-get? voting-status { sighting-id: sighting-id }) (err ERR-INVALID-SIGHTING)))
    )
    ;; Simplified: In full impl, iterate over votes and slash/reward
    (ok true)
  )
)

;; Read-Only Functions
(define-read-only (get-verifier-status (verifier principal))
  (map-get? verifiers { verifier: verifier })
)

(define-read-only (get-voting-status (sighting-id uint))
  (map-get? voting-status { sighting-id: sighting-id })
)

(define-read-only (get-vote (sighting-id uint) (verifier principal))
  (map-get? votes { sighting-id: sighting-id, verifier: verifier })
)

(define-read-only (is-paused)
  (var-get paused)
)

(define-read-only (get-admin)
  (var-get admin)
)