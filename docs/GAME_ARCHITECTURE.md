# CueStrike game architecture

## Product rule

CueStrike is a skill game. Every player receives the same table geometry, physics constants, controls, turn rules, and matchmaking inputs. Cosmetic cues, table skins, avatars, NFTs, and rewards must never improve aim, power, collision behavior, input timing, or opponent selection.

The browser build is intentionally safe before deployment. Practice and local simulations are playable. They cannot mint rewards, settle wagers, unlock an airdrop, or declare an onchain winner. A player device is never a trusted result oracle.

## Eight ball rules implemented

1. A rack starts with an open table.
2. The first legally pocketed solid or stripe assigns both groups.
3. A legal shot contacts the current group first, or the eight ball after the group is cleared.
4. After contact, a ball must enter a pocket or any ball must reach a rail.
5. A legal break pockets a ball or drives at least four object balls to rails.
6. An eight ball made on the break is respotted and does not decide the frame.
7. A white ball scratch places the incoming player on the baulk line and permits only a forward shot. No contact, wrong first contact, illegal break, or no rail after contact gives normal ball in hand.
8. Pocketing the eight ball after clearing the assigned group wins. An early eight ball or an eight ball on a foul loses.

Production rules must add called pocket selection, shot clocks, break alternation, deliberate stalemate handling, and an off table ball policy before ranked launch. These settings must be versioned so both players and every oracle verify the same rule set.

## Client targets

The installable web app, Android project, and iOS project share the same deterministic rules and rendering code. Capacitor provides the native containers, landscape configuration, splash screens, icons, offline assets, and haptic feedback. Platform signing credentials remain outside source control. The mobile wallet adapter, push notifications, store privacy declarations, age ratings, and release signing must be completed before store submission.

## Modes and contract actions

| Mode | Entry | Result authority | Contract outcome |
| --- | --- | --- | --- |
| Practice | Free | None | No token action |
| Ranked | Free | Authoritative server and approved oracle | `CueRewardsPool` pays the verified winner reward |
| Direct match | Equal CUE from two players | Oracle certificate, with extra consensus for high value play | `CueEscrow` sends 98 percent to the winner, 1 percent to burn, and 1 percent to rewards before any allowed NFT bonus |
| Sixteen player | Fixed CUE tier | Two oracle result signatures | `CueSitAndGo` sends 70 percent to first, 20 percent to second, 8 percent to burn, and 2 percent to development |
| Championship | Published tier and bracket | Oracle verified bracket results | `CueTournament` sends 60 percent to first, 20 percent to second, 10 percent to burn, and 10 percent to DAO |

The client approves only the exact entry amount. BNB is used only for network gas. There are no card, bank, Stripe, or PayPal deposit paths.

## Authoritative match lifecycle

1. The API authenticates the wallet with a one time nonce and signature.
2. Matchmaking creates an immutable match record containing players, rule version, physics version, entry tier, region, and expiry.
3. For paid play, the contract confirms both entries before the server releases a table session token.
4. Both clients send signed, numbered input commands through a WebSocket connection.
5. The server applies inputs to a fixed timestep simulation. It owns the canonical ball state and broadcasts snapshots.
6. Every input, state checksum, foul, pause, and reconnection enters an append only transcript hash chain.
7. At completion, an independent replay worker reruns the transcript. Result oracles sign only if the replay checksum and canonical result match.
8. The settlement worker submits an expiring, nonce protected certificate to the matching contract and waits for final chain confirmation.
9. Referral volume, achievements, ranking, and airdrop progress update only after the verified completion event.

## Anti cheat controls

- Server owned physics prevents a modified client from moving balls or inventing a win.
- Monotonic input sequence numbers reject replays, duplicates, and reordered shots.
- Fixed timestep simulation and versioned constants make every match reproducible.
- Short lived session keys bind inputs to one player, device session, and match.
- Velocity, aim, power, timing, and impossible collision checks reject invalid commands.
- Server snapshots and client checksums reveal state divergence quickly.
- Encrypted transport protects sessions; it does not replace signed commands or server validation.
- Replay analysis, behavior scoring, collusion graphs, device risk signals, and manual review support enforcement.
- Oracle keys remain separate from game servers and settlement workers. High value matches use the contract required consensus.
- Rate limits, queue cooldowns, opponent diversity checks, and repeated counterparty review reduce farming and wash play.

Anti cheat detection should quarantine a disputed result. It should not confiscate funds automatically from a machine learning score. Financial action needs deterministic evidence, an appeal process, and the contract path allowed for that match.

## Failure handling

| Scenario | Required behavior |
| --- | --- |
| Temporary disconnect | Freeze the shot clock, preserve canonical state, and allow a short authenticated reconnect window |
| Reconnect with stale state | Send the latest server snapshot and accept only the next unused input sequence |
| Player abandons | Produce a forfeit only after heartbeat expiry and oracle verification |
| Both players cannot start | Use cancellation or timeout refund paths; never invent a winner |
| Game server stops | A standby server resumes from the event stream; otherwise contract timeout protection remains available |
| Oracle unavailable | Keep the match pending and retry safely; do not accept a client supplied result |
| Conflicting oracle result | Quarantine settlement and alert operations |
| Duplicate settlement | Contract nonce and finalized match state reject it; worker treats the existing receipt as success |
| Chain reorganization | Wait the configured confirmation depth before marking settlement final |
| Contract paused | Stop new paid matchmaking and keep read only status plus recovery instructions available |
| Insufficient CUE or allowance | Reject before queue entry and show the exact required balance and approval |
| Wallet rejects transaction | Leave the player outside the paid queue with no game result |
| High value direct match | Require the additional oracle approval encoded by `CueEscrow` |
| Tournament stalls | Follow the onchain progress timeout and pull refund process |
| Suspicious play | Quarantine rewards, retain replay evidence, and route to review and appeal |

## Services needed for a real launch

- A regional WebSocket gateway and deterministic match servers
- PostgreSQL for accounts, matches, tournaments, and financial reconciliation
- An append only event stream and object storage for signed replay records
- Redis for presence, queues, rate limits, and reconnect state
- Separate replay workers, oracle signers, and settlement workers
- Hardware backed production keys, multisig administration, alerting, and incident runbooks
- Identity, age, sanctions, location, responsible play, limits, self exclusion, privacy, and retention controls based on licensed legal advice in each launch market
- Load tests, penetration tests, economic tests, smart contract audits, game fairness review, and testnet rehearsals

The game should launch in stages: free practice, closed ranked testing, public ranked play, low tier paid testnet or legally approved pilot, then higher tiers only after retention, fraud, dispute, liquidity, and settlement data demonstrate that the system is safe.
