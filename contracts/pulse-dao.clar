;; pulse-dao.clar
;; 
;; This contract implements a governance system for decentralized health cooperatives,
;; managing member registration, proposal submission, voting, and decision execution.
;; It uses quadratic voting to balance stakeholder influence and includes delegation capabilities
;; to allow members to assign voting rights to healthcare experts or trusted representatives.

;; ========== Error Constants ==========
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-MEMBER-NOT-FOUND (err u101))
(define-constant ERR-PROPOSAL-NOT-FOUND (err u102))
(define-constant ERR-INVALID-STATE (err u103))
(define-constant ERR-ALREADY-VOTED (err u104))
(define-constant ERR-VOTING-CLOSED (err u105))
(define-constant ERR-INSUFFICIENT-STAKE (err u106))
(define-constant ERR-INVALID-VOTE-AMOUNT (err u107))
(define-constant ERR-SELF-DELEGATION (err u108))
(define-constant ERR-DELEGATION-CYCLE (err u109))
(define-constant ERR-PROPOSAL-LIMIT-REACHED (err u110))
(define-constant ERR-EMERGENCY-NOT-AUTHORIZED (err u111))
(define-constant ERR-NOT-IMPLEMENTED (err u112))

;; ========== Contract Variables ==========
;; Administrative settings
(define-data-var admin principal tx-sender)
(define-data-var proposal-counter uint u0)
(define-data-var quorum-percentage uint u30)
(define-data-var voting-period uint u7) ;; Default 7 days
(define-data-var emergency-committee (list 10 principal) (list))

;; ========== Data Maps ==========
;; Member information
(define-map members 
  { address: principal }
  {
    stake: uint,
    verified: bool,
    join-time: uint,
    role: (string-ascii 50),
    delegate: (optional principal)
  }
)

;; Proposal data
(define-map proposals
  { id: uint }
  {
    title: (string-ascii 100),
    description: (string-utf8 4000),
    proposer: principal,
    category: (string-ascii 50),
    state: (string-ascii 20),  ;; draft, active, passed, rejected, implemented
    created-at: uint,
    voting-ends-at: uint,
    is-emergency: bool,
    implementation-details: (optional (string-utf8 1000)),
    yes-votes: uint,
    no-votes: uint,
    abstain-votes: uint,
    min-stake-to-vote: uint
  }
)

;; Voting records
(define-map votes
  { proposal-id: uint, voter: principal }
  {
    vote: (string-ascii 10),  ;; yes, no, abstain
    power: uint,
    time: uint
  }
)

;; Vote delegation records
(define-map delegations
  { delegator: principal }
  {
    delegate: principal,
    active: bool,
    delegation-time: uint
  }
)

;; ========== Private Functions ==========
;; Calculate quadratic voting power based on stake
(define-private (calculate-voting-power (stake uint))
  (to-uint (+ u1 (pow stake u0.5)))
)

;; Check if a principal is a verified member
(define-private (is-verified-member (address principal))
  (match (map-get? members { address: address })
    member (get verified member)
    false
  )
)

;; Get a member's stake
(define-private (get-member-stake (address principal))
  (match (map-get? members { address: address })
    member (get stake member)
    u0
  )
)

;; Check if a proposal exists and is in a given state
(define-private (is-proposal-in-state (proposal-id uint) (state (string-ascii 20)))
  (match (map-get? proposals { id: proposal-id })
    proposal (is-eq (get state proposal) state)
    false
  )
)

;; Check if voting period is active for a proposal
(define-private (is-voting-active (proposal-id uint))
  (match (map-get? proposals { id: proposal-id })
    proposal (< block-height (get voting-ends-at proposal))
    false
  )
)

;; Check if a member has already voted on a proposal
(define-private (has-voted (proposal-id uint) (voter principal))
  (is-some (map-get? votes { proposal-id: proposal-id, voter: voter }))
)

;; Get the effective voter (follow delegation chain if exists)
(define-private (get-effective-voter (voter principal))
  (match (map-get? delegations { delegator: voter })
    delegation 
      (if (get active delegation)
        (let ((delegate (get delegate delegation)))
          ;; Prevent circular delegations by only allowing one level of delegation
          delegate
        )
        voter
      )
    voter
  )
)

;; Check if a principal is in the emergency committee
(define-private (is-emergency-committee-member (address principal))
  (is-some (index-of (var-get emergency-committee) address))
)

;; Update proposal state
(define-private (update-proposal-state (proposal-id uint) (new-state (string-ascii 20)))
  (match (map-get? proposals { id: proposal-id })
    proposal 
      (map-set proposals 
        { id: proposal-id }
        (merge proposal { state: new-state })
      )
    false
  )
)

;; ========== Read-Only Functions ==========
;; Get proposal details
(define-read-only (get-proposal (proposal-id uint))
  (map-get? proposals { id: proposal-id })
)

;; Get member details
(define-read-only (get-member (address principal))
  (map-get? members { address: address })
)

;; Get vote details for a proposal and voter
(define-read-only (get-vote (proposal-id uint) (voter principal))
  (map-get? votes { proposal-id: proposal-id, voter: voter })
)

;; Get delegation details
(define-read-only (get-delegation (delegator principal))
  (map-get? delegations { delegator: delegator })
)

;; Check if a proposal has reached quorum
(define-read-only (has-reached-quorum (proposal-id uint))
  (match (map-get? proposals { id: proposal-id })
    proposal 
      (let (
        (total-votes (+ (get yes-votes proposal) (get no-votes proposal) (get abstain-votes proposal)))
        (total-stake (fold + (map get-member-stake (map-get members)) u0))
        (required-stake (/ (* total-stake (var-get quorum-percentage)) u100))
      )
      (>= total-votes required-stake))
    false
  )
)

;; Get the result of a proposal after voting ends
(define-read-only (get-proposal-result (proposal-id uint))
  (match (map-get? proposals { id: proposal-id })
    proposal 
      (if (is-eq (get state proposal) "active")
        (err "Voting still active")
        (ok {
          yes-votes: (get yes-votes proposal),
          no-votes: (get no-votes proposal),
          abstain-votes: (get abstain-votes proposal),
          state: (get state proposal)
        }))
    (err "Proposal not found")
  )
)

;; ========== Public Functions ==========
;; Register as a new member
(define-public (register-member (role (string-ascii 50)) (initial-stake uint))
  (let ((caller tx-sender))
    (if (is-some (map-get? members { address: caller }))
      ERR-NOT-AUTHORIZED
      (begin
        (map-set members
          { address: caller }
          {
            stake: initial-stake,
            verified: false,
            join-time: block-height,
            role: role,
            delegate: none
          }
        )
        (ok true)
      )
    )
  )
)

;; Verify a member (admin only)
(define-public (verify-member (address principal))
  (let ((caller tx-sender))
    (asserts! (is-eq caller (var-get admin)) ERR-NOT-AUTHORIZED)
    (match (map-get? members { address: address })
      member (begin
        (map-set members
          { address: address }
          (merge member { verified: true })
        )
        (ok true)
      )
      ERR-MEMBER-NOT-FOUND
    )
  )
)

;; Add stake to your membership
(define-public (add-stake (amount uint))
  (let ((caller tx-sender))
    (match (map-get? members { address: caller })
      member (begin
        (map-set members
          { address: caller }
          (merge member { stake: (+ (get stake member) amount) })
        )
        (ok true)
      )
      ERR-MEMBER-NOT-FOUND
    )
  )
)

;; Create a new proposal
(define-public (create-proposal 
  (title (string-ascii 100)) 
  (description (string-utf8 4000)) 
  (category (string-ascii 50)) 
  (is-emergency bool)
  (min-stake-to-vote uint)
  (implementation-details (optional (string-utf8 1000)))
)
  (let (
    (caller tx-sender)
    (proposal-id (+ (var-get proposal-counter) u1))
    (voting-duration (var-get voting-period))
  )
    (asserts! (is-verified-member caller) ERR-NOT-AUTHORIZED)
    
    ;; For emergency proposals, check if user is authorized
    (asserts! (or (not is-emergency) (is-emergency-committee-member caller)) ERR-EMERGENCY-NOT-AUTHORIZED)
    
    ;; Create the proposal
    (map-set proposals
      { id: proposal-id }
      {
        title: title,
        description: description,
        proposer: caller,
        category: category,
        state: "active",
        created-at: block-height,
        voting-ends-at: (+ block-height voting-duration),
        is-emergency: is-emergency,
        implementation-details: implementation-details,
        yes-votes: u0,
        no-votes: u0,
        abstain-votes: u0,
        min-stake-to-vote: min-stake-to-vote
      }
    )
    
    ;; Increment proposal counter
    (var-set proposal-counter proposal-id)
    (ok proposal-id)
  )
)

;; Vote on a proposal
(define-public (vote (proposal-id uint) (vote-type (string-ascii 10)))
  (let (
    (caller tx-sender)
    (effective-voter (get-effective-voter caller))
  )
    ;; Check if caller is a verified member
    (asserts! (is-verified-member caller) ERR-NOT-AUTHORIZED)
    
    ;; Check if proposal exists and is active
    (asserts! (is-proposal-in-state proposal-id "active") ERR-INVALID-STATE)
    
    ;; Check if voting period is still open
    (asserts! (is-voting-active proposal-id) ERR-VOTING-CLOSED)
    
    ;; Check if the voter has already voted
    (asserts! (not (has-voted proposal-id effective-voter)) ERR-ALREADY-VOTED)
    
    ;; Get member stake and calculate voting power (quadratic voting)
    (match (map-get? members { address: effective-voter })
      member 
        (let (
          (stake (get stake member))
          (proposal (unwrap! (map-get? proposals { id: proposal-id }) ERR-PROPOSAL-NOT-FOUND))
          (min-stake (get min-stake-to-vote proposal))
          (voting-power (calculate-voting-power stake))
        )
          ;; Check if member has minimum required stake
          (asserts! (>= stake min-stake) ERR-INSUFFICIENT-STAKE)
          
          ;; Record the vote
          (map-set votes
            { proposal-id: proposal-id, voter: effective-voter }
            {
              vote: vote-type,
              power: voting-power,
              time: block-height
            }
          )
          
          ;; Update proposal vote counts
          (map-set proposals
            { id: proposal-id }
            (merge proposal 
              {
                yes-votes: (if (is-eq vote-type "yes") (+ (get yes-votes proposal) voting-power) (get yes-votes proposal)),
                no-votes: (if (is-eq vote-type "no") (+ (get no-votes proposal) voting-power) (get no-votes proposal)),
                abstain-votes: (if (is-eq vote-type "abstain") (+ (get abstain-votes proposal) voting-power) (get abstain-votes proposal))
              }
            )
          )
          (ok true)
        )
      ERR-MEMBER-NOT-FOUND
    )
  )
)

;; Delegate voting power to another member
(define-public (delegate-vote (delegate-to principal))
  (let ((caller tx-sender))
    ;; Check if caller is a verified member
    (asserts! (is-verified-member caller) ERR-NOT-AUTHORIZED)
    
    ;; Check if delegate is a verified member
    (asserts! (is-verified-member delegate-to) ERR-MEMBER-NOT-FOUND)
    
    ;; Prevent self-delegation
    (asserts! (not (is-eq caller delegate-to)) ERR-SELF-DELEGATION)
    
    ;; Set delegation
    (map-set delegations
      { delegator: caller }
      {
        delegate: delegate-to,
        active: true,
        delegation-time: block-height
      }
    )
    (ok true)
  )
)

;; Remove delegation
(define-public (remove-delegation)
  (let ((caller tx-sender))
    (match (map-get? delegations { delegator: caller })
      delegation (begin
        (map-set delegations
          { delegator: caller }
          (merge delegation { active: false })
        )
        (ok true)
      )
      ERR-NOT-AUTHORIZED
    )
  )
)

;; Finalize a proposal after voting ends
(define-public (finalize-proposal (proposal-id uint))
  (let ((caller tx-sender))
    ;; Check if proposal exists and is active
    (asserts! (is-proposal-in-state proposal-id "active") ERR-INVALID-STATE)
    
    ;; Check if voting period has ended
    (asserts! (not (is-voting-active proposal-id)) ERR-INVALID-STATE)
    
    (match (map-get? proposals { id: proposal-id })
      proposal 
        (let (
          (yes-votes (get yes-votes proposal))
          (no-votes (get no-votes proposal))
          (new-state (if (> yes-votes no-votes) "passed" "rejected"))
        )
          (update-proposal-state proposal-id new-state)
          (ok true)
        )
      ERR-PROPOSAL-NOT-FOUND
    )
  )
)

;; Mark a proposal as implemented (admin or proposer only)
(define-public (mark-implemented (proposal-id uint) (implementation-notes (string-utf8 1000)))
  (let ((caller tx-sender))
    ;; Check if proposal exists and is passed
    (asserts! (is-proposal-in-state proposal-id "passed") ERR-INVALID-STATE)
    
    (match (map-get? proposals { id: proposal-id })
      proposal 
        (let ((proposer (get proposer proposal)))
          ;; Only admin or original proposer can mark as implemented
          (asserts! (or (is-eq caller (var-get admin)) (is-eq caller proposer)) ERR-NOT-AUTHORIZED)
          
          (map-set proposals
            { id: proposal-id }
            (merge proposal { 
              state: "implemented",
              implementation-details: (some implementation-notes)
            })
          )
          (ok true)
        )
      ERR-PROPOSAL-NOT-FOUND
    )
  )
)

;; Update emergency committee (admin only)
(define-public (update-emergency-committee (new-committee (list 10 principal)))
  (let ((caller tx-sender))
    (asserts! (is-eq caller (var-get admin)) ERR-NOT-AUTHORIZED)
    (var-set emergency-committee new-committee)
    (ok true)
  )
)

;; Update governance parameters (admin only)
(define-public (update-governance-params 
  (new-quorum-percentage (optional uint)) 
  (new-voting-period (optional uint))
)
  (let ((caller tx-sender))
    (asserts! (is-eq caller (var-get admin)) ERR-NOT-AUTHORIZED)
    
    ;; Update quorum percentage if provided
    (match new-quorum-percentage
      quorum (var-set quorum-percentage quorum)
      true
    )
    
    ;; Update voting period if provided
    (match new-voting-period
      period (var-set voting-period period)
      true
    )
    
    (ok true)
  )
)

;; Transfer admin rights to a new principal
(define-public (transfer-admin (new-admin principal))
  (let ((caller tx-sender))
    (asserts! (is-eq caller (var-get admin)) ERR-NOT-AUTHORIZED)
    (var-set admin new-admin)
    (ok true)
  )
)