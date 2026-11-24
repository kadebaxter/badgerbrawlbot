defmodule Swarm.Brain do
  @moduledoc """
  The leader's team-level decisions. Pure: view + memory in, strategy + commands + memory out.

  - The **strategy** is broadcast to every unit, and each unit interprets it for itself
    (`Swarm.UnitBrain`).
  - The **commands** are the ones no single unit owns: buildings, training and research.
  - The **memory** is the little the leader remembers between ticks. It is replicated through
    `ra`, so a new leader picks up where the old one stopped.

  Economy: grow to ~20 workers (30 in a big game) while following `@build_order` (Barracks, a Resource Depot by the
  ore, Guard Towers toward the enemy, a TechLab, ...), research upgrades, and train soldiers and
  archers with what is left. Ore for the next building is set aside first, so the rest of the
  spending never makes it late.

  The ore we have seen is remembered (`see/2`), and the first scout surveys our side for more
  (`strategy.survey`), so workers have somewhere to go when the ore by our drop-offs runs out or
  the enemy sits on it. Once a Barracks is up, `@worker_reserve` ore stays back for workers.

  Army: fighters work out their own roles (`Swarm.Roles`). A Scout per opponent explores. The leader
  remembers every enemy fighter it has seen, and launches a wave once the attackers waiting at
  the rally point are `@margin` times as strong as the enemy army and towers we know of (at
  least `@min_wave` of them; `@first_wave` while we know nothing; in a big game, `@big_first_wave`
  for the first and `@big_min_wave` after, with a ring of towers and a third Barracks first). While it is out, later ones
  follow it in batches of `@batch`, and count as part of it. The wave is recalled when it meets a stronger force, when fewer than
  `@recall_below` are left, or when whatever is hitting us at home (any base, or our workers) is
  stronger than what is home. A wave only leaves if what stays home can hold the raid going on
  (a scout poking at the base holds nothing up), and not within `@calm_ticks` of a recall for home.
  Right after we beat a raid it may go with every attacker near the rally point (a
  counterattack). Before a wave leaves, a scout looks at the target (`strategy.look`; while it is
  out, a scout works in front of it), so the
  launch goes on what is there now: enemies we remember where our units can see and don't are
  forgotten. Fights are judged against the strongest single enemy player there: two others fighting
  each other don't add up (we can come in on them). When no wave leaves, `strategy.hold` says why,
  for the logs. In the last `@all_in_ticks` ticks, if we are behind on score,
  every fighter attacks: sitting still would lose on time anyway.
  """

  alias Swarm.{Reads, Roles, View}

  @target_workers 20
  # A big game needs a bigger economy to out-grow everyone: this many workers there.
  @big_target_workers 30
  # More than that while there is the ore for them: a worker for every `@ore_per_worker` ore left in
  # the fields we can mine or take (`minable_ore/1`), up to `@max_workers`. A worker (50) pays for
  # itself in about 35 ticks of mining, and every ore banked counts twice on time: once as gathered,
  # again in what it buys.
  @ore_per_worker 150
  @max_workers 80
  # Scouts: one per neighbor, waiting halfway to them (see `Swarm.UnitBrain`).
  @scouts 2
  @first_wave 15
  # Every wave, counterattacks too, needs at least this many attackers: a handful sent at a
  # neighbor gets turned back and picked off. In a big game (`@big_game` players or more), where
  # neighbors are close and armies big, we turtle up first: no wave before `@big_first_wave`, then
  # at least `@big_min_wave` each.
  @min_wave 12
  @big_game 6
  @big_first_wave 18
  @big_min_wave 15
  # In a big game, no new co-op (Resource Depot away from home) before this many fighters: one
  # with nobody to hold it is lost.
  @expand_army 15
  # The serum (once a match, Soldiers ×2 for 30 ticks), for home being overrun: only with this many
  # soldiers, and only for a raid at least this strong (about four soldiers).
  @serum_soldiers 8
  @serum_raid 8000
  # ... a wave this many tiles (ticks) from the raid can be back in time: it counts as help;
  # without one, the raid must be at least this many times what home has.
  @help_eta 15
  @serum_margin 1.0
  # A strike at an enemy tower by our base: at least this many fighters (eight soldiers take a tower
  # down in about nine ticks), as strong as the tower plus `@margin` times the strongest player's
  # units by it (`Swarm.Roles.strength/1`, the one measure); given up after `@strike_ticks`, and
  # not tried again for `@strike_rest` ticks after one comes back.
  @strike_min 8
  @strike_ticks 120
  @strike_rest 20
  # Siege by our base (see `siege_watch/2` and `sortie/3`): checkers, how far out around the
  # building they look, for how long; a sortie's smallest size and longest outing.
  @checkers 4
  @check_radius 7
  # After a checker dies, no new checkers for this long (a scout looks instead), and how long the
  # scout has to get there.
  @check_rest 60
  @peek_ticks 40
  @check_ticks 60
  @sortie_min 4
  # A sortie leaves at this many times what is there: it is recalled once outmatched, so leaving at
  # even strength had it called back the moment one more enemy showed up, and out again, and back.
  @sortie_margin 1.3
  @sortie_ticks 100
  # Enemy sites this close to one of our bases are razed (finished buildings within 12).
  @raze_reach 12
  @raze_built 10
  # The backup Command Center (see `site/4`, `:hideout`): a map corner is free with no base start
  # within `@corner_free` of it, and the backup goes within `@corner_zone` of one; at least
  # `@backup_near` from our base; along our edge (failing a free corner) no more than `@backup_to`
  # from it, and no nearer the middle than it by more than `@edge_slack`.
  @corner_free 15
  @corner_zone 10
  @backup_near 12
  @backup_to 30
  @edge_slack 3
  # The early strike on a weak, close neighbor (see `early_strike?/6`).
  @early_min 10
  @early_reach 30
  @early_margin 2
  # The first wave in a big game waits for the tower square, but not past this tick.
  @square_deadline 900
  @margin 1.5
  # Enemy fighters we remember this close to our Command Center are an army near home (see
  # `army_near_home/3`).
  @home_watch 20
  # A wave, strike or sortie down this share of the most it has had is called off (`bleeding/2`).
  @call_off 0.35
  # A wave may have this many fighters, or two thirds of the army once that is more (`wave_cap/1`).
  @wave_floor 20
  # A spot where we lost a building is avoided while enemy fighters are this close to it.
  @lost_clear 10
  # Falling back holds this many ticks past the last reason to.
  @fall_back_hold 15
  # Helping (see `help/3`): it follows the fight this far, ends after this long with nothing there,
  # and is called off when what is there is this many times what home can bring.
  @help_follow 8
  @help_clear 15
  @help_give_up 1.3
  # After help is called off, no new help for this long.
  @help_rest 20
  # Where help was called off is remembered this long (see `may_help?/4`).
  @help_memory 120
  # The army at a forward base is called home for enemy fighters this close to the main Command
  # Center; those of ours and our towers within `@home_call_base` of it are the ones at home; and
  # it stays home this long after the last of them is gone.
  @home_call 15
  @home_call_base 10
  @home_call_hold 20
  # The main base is overrun by enemies this many times all of home; regrouping holds this long
  # after the last tick it was (see `regroup/2`). The base's reach is `Swarm.Roles`'.
  @overrun_margin 1.5
  @regroup_hold 40
  @backup_workers 2
  @base_radius 10
  @recall_below 5
  # While a wave is out, attackers at the rally point go after it this many at a time.
  @batch 5
  # Right after we beat a raid (`@counter_kills` of its fighters killed at home, the last of it
  # gone within `@counter_window` ticks), a wave may leave with every attacker this close to the
  # rally point, not only the ones standing at it: hit back while they are weak.
  @counter_kills 3
  @counter_window 50
  # A raid out of sight this long is gone (see `counter?/2`); no wave leaves before that.
  @raid_gone 20
  @counter_radius 10
  # Before a wave leaves, a scout looks at the target: once `@look_at` attackers wait at the rally
  # point, unless we looked at that player in the last `@look_fresh` ticks. It runs through to
  # the target itself, whatever is in the way (`Swarm.UnitBrain`); the look is done once a scout
  # has the target well inside its sight (its vision is 8). The launch waits at most
  # `@look_timeout` ticks for it. A look from seven tiles short was "done" by a scout passing 13
  # tiles from their base that had seen none of it: "0 fighters", and a wave of 15 left into 41.
  @look_at 5
  @look_after_kills 8
  @serum_contact 6
  @look_fresh 60
  @look_sight 3
  @look_timeout 40
  # How far our units see, for forgetting enemies we should see and don't (one less, as they move).
  @vision %{"Scout" => 8, "Archer" => 6, "Trebuchet" => 7, "GuardTower" => 7}
  @default_vision 6
  @all_in_ticks 300
  # The most we have known of a player's army counts for this long (`army_seen/3`), whatever we
  # can see of it now: a scout that looks at the wrong spot sees no army, not that there is none.
  # A wave of 16 left against "9,900 known" 37 ticks after a scout had counted 22,770.
  @army_memory 150
  # Their army (that count) bigger than all our fighters: the army stays in one group at home
  # (`together`): no escorts at the outposts. Until theirs is under `@together_until` of ours
  # again (the same measure, with a margin, so it doesn't flip). And home only goes out to help
  # where it can take that whole count, not just the raiders in sight (`may_help?/4`).
  @together_until 0.8
  # A scout's look at a player (`look/5`) that finds less than that count brings it down, but to
  # no less than this share of it: a scout sees one spot, and the army may be standing at another.
  @look_trust 0.5
  # A scout that dies on its way in, or doesn't get there in time, but saw their fighters on the
  # way: their army is there. It only saw the nearest few, so the count is theirs by the
  # scoreboard (`army_by_score/2`), if that is more. That is a look, and the wave is weighed
  # against that count like any. One stood six tiles from 40 Soldiers for 25 ticks, the look timed
  # out as nothing learned, and a wave of 19 left on a count of 13.
  # With no ore left that we can get at and no Scout alive, from this tick on, an idle worker does
  # the looking before a wave (`stand_in/1`).
  @stand_in_from 300
  # Nothing left to mine (`nothing_to_mine/2`), two ways, neither going by what we happen to see:
  # - for certain: the ore the map started with, less what every player has banked (the server
  #   reports it for all), is under `@ore_dregs` of it. The map's ore is the same every game
  #   (`map_ore/2`): four corners of 18,000 with two to four players, 14,100 a player on a ring,
  #   scaled by our own home piles (1,000 each as a rule). That count only errs one way: ore mined
  #   and never banked (lost over a storage cap, or with the worker carrying it) still counts as
  #   left, up to a sixth of the map in the games on record, so much may look left with none there.
  # - so also: we have banked nothing for `@ore_stall` ticks with `@rebuild_workers` workers or more
  #   and none of them mining. Whatever is left, we aren't getting it.
  @ore_dregs 0.02
  @ore_stall 100
  # Stalled, we go and find the ore (`ore_search/3`): up to `@searchers` idle workers walk to the
  # places we haven't looked at, each to its own, until we bank again or there is nowhere left to
  # look. A worker gets `@search_timeout` ticks for a place (it may not be able to get there).
  @searchers 4
  @search_timeout 90
  @corner_ore 18_000
  @ring_ore 14_100
  # After a wave is called home to defend, no new one leaves for this long: raiders often come
  # back, and a wave that leaves the moment they step out of sight gets called home again.
  @calm_ticks 20
  # An enemy fighter not seen for this long is forgotten: we can't trust where it was.
  @forget_after 300
  # Enemy fighters out of sight still count as danger this many ticks after we last saw them.
  @recent_enemy_ticks 5
  # How far from the wave's center enemies count when deciding to pull back.
  @wave_sight 8
  # How close to the rally point an attacker must be to leave with a wave.
  @staged_radius 3
  # After a defend, attackers this close together out at an outpost or by our workers may leave
  # with a wave from there, without walking home first (see `launch_group/4`).
  @field_radius 6
  # Where the army waits by the last Command Center we leave standing (`spare/3`): out of an
  # Archer's reach (4) of it, so standing there idle nobody shoots it; Trebuchets (reach 7) farther.
  @camp_distance 6
  # Safe mode takes a real army hitting home: at least this much (`Roles.strength/2`, 5 Soldiers).
  # One archer with everyone out called it once, and the match ended 1100 ticks early.
  @safe_raid 5 * 990
  @siege_camp_distance 9
  # It comes down this many ticks before the end, for its 400 and the win by elimination: the
  # army at the camp walks the 6 tiles and knocks its 1500 HP down in about ten.
  @spare_until 30
  # How far a Guard Tower shoots (ours or theirs).
  @tower_reach 5
  # An ordered building that hasn't appeared by then is ordered again.
  @build_timeout_ticks 60
  # A worker sent to finish an abandoned site gets this long to show up before we send another.
  @help_wait_ticks 10

  @costs %{
    "Worker" => 50,
    "Soldier" => 100,
    "Archer" => 125,
    "Scout" => 75,
    "CommandCenter" => 400,
    "Barracks" => 150,
    "ResourceDepot" => 100,
    "GuardTower" => 125,
    "TechLab" => 150,
    "Harvesting1" => 100,
    "Weapons1" => 150,
    "Armor1" => 150,
    "Harvesting2" => 200,
    "Weapons2" => 250,
    "Armor2" => 250,
    "Armor3" => 350,
    "Fortify1" => 150,
    "Fortify2" => 250,
    "SiegeEngineering" => 200,
    "SiegeWorkshop" => 250,
    "Trebuchet" => 350
  }

  # Ore on hand that counts as rich, once the first Barracks is up (the 500 we start with doesn't
  # count): then the build order stops waiting for workers (except for depots), more gets built
  # (`@extras`), each building gets two builders, and Barracks queue up to five.
  @rich 500

  # The fewest fighters to have before ore goes to anything else: this many, plus one per
  # `@army_floor_ticks` ticks. Below it, the Barracks train first.
  @army_floor 6
  @army_floor_ticks 100
  @help_chase 3
  @base_slack 4
  # An opponent with this much ore or less alive outside the buildings we know of has no army.
  @no_army_ore 1500
  @help_cover 5
  @score_floor_from 120

  # Built once the build order is done and only while rich, one at a time, in this order.
  @extras [
    {"GuardTower", 3, :front},
    {"GuardTower", 4, :front},
    {"GuardTower", 5, :front},
    {"GuardTower", 6, :square},
    {"GuardTower", 7, :square},
    {"GuardTower", 8, :square}
  ]
  @tower_from 100
  @first_depot_builders 3

  # Siege is only for knocking down the enemy's towers with a wave: at home a Trebuchet (350 ore)
  # is a fifth as strong as the 3.5 Soldiers it costs, and can't hit anything close. So
  # SiegeEngineering, the SiegeWorkshop and the Trebuchets wait for this many fighters (and the
  # build order to be done), and then we keep `@trebuchets` of them, for the waves.
  # Another Barracks whenever every one we have is busy (`more_barracks/3`), up to `@max_barracks`:
  # 60 workers earned more than four Barracks could spend, and 2,500 ore sat in the bank while the
  # base fell. It has its own order (`barracks_order`), apart from the one building at a time of
  # the rest: 22 depots and towers in a row (some ordered four times over) kept that one slot for
  # 300 ticks, with five Barracks full, 5,258 ore in the bank and 49 Soldiers on their way.
  @max_barracks 14
  @barracks_bank 750
  # Base Command Centers (`base_cc/3`): a Command Center of our own by a field worth one, to mine
  # it, train workers there too and have somewhere else to stand. One more at each of these worker
  # counts (the second at 16, and so on), once the first Barracks is up. A field is worth one with
  # `@base_ore` or more in it and nothing of a living enemy's near: `@base_clear` tiles from their
  # starts and buildings we know of, `@base_watch` from their fighters we remember. On two- to
  # four-player maps the fields we haven't seen count too: the map is mirrored both ways
  # (`inferred_ore/2`). An eliminated player's start comes first, but only once a scout has seen it
  # clear in the last `@clear_for` ticks; the scout goes back to look every `@recheck` ticks.
  @cc_at_workers [16, 30, 50]
  # ...and only with an army to hold it: `@base_army` fighters or more. Two bases and their towers
  # were bought with 8 to 14 fighters alive; 23 Soldiers took the first, then the army. (Not
  # "only while their army isn't the bigger one": the strongest opponent's always is, early, and
  # with their army counted by the scoreboard no base went up in a whole game.)
  # Saving for one never holds soldiers back: while we are short of its 400, every Barracks goes
  # on training one at a time, as fast as ever; only the second place in each queue (paid for
  # ahead, no sooner trained) waits for it.
  @base_army 12
  # Where it goes: the safest field first. How safe: how far it is from the nearest living enemy's
  # start or building we know of, or twice how far from the middle of the map if that is less
  # (the middle is where everyone expands to and every army crosses), up to `@safe_enough`;
  # equally safe, the nearer us. So our own side's field and the free corners before the middle.
  @safe_enough 30
  # Except the first: until we have a base in the middle of the map (within a quarter of the
  # map's width of its center), the fields there come first, the nearest to us. The middle holds
  # the most ore on the map (21,600 of 72,000 with two to four players), and whoever sits there
  # with an army keeps everyone else off it: with our first base in a far corner, the hardest
  # house bot took the whole middle and out-mined us two to one. Our army then lives at that base
  # (`rally/1`): the rally point is there, not at home, and it gets `@forward_towers` towers.
  @forward_towers 4
  @base_ore 2500
  @base_clear 14
  @base_watch 12
  @base_builders 3
  @base_towers 2
  @mirror_players 4
  @recheck 20
  @clear_for 45
  # A base's builders get this long to break ground (they may walk 50 tiles) before we give up.
  @base_timeout 150
  # A second TechLab once we have this many workers and the first is up, ahead of the rest of the
  # build order: two upgrades at a time.
  @second_lab_workers 25
  # (It was 25 fighters and the whole build order done: the first Trebuchets came at tick 650 to
  # 1100. Their workers stand a dozen and more to a tile while they mine, and a shell hits
  # everything on the tile it lands on: Trebuchets are for those as much as for towers.)
  @siege_after_fighters 15
  @trebuchets 2
  # More against a wall of towers: one for every `@towers_per_trebuchet` finished towers of the
  # opponent who has the most we know of, up to `@max_trebuchets`. Two take about 56 ticks a tower
  # (40 damage every 8 ticks against 500 HP), six about 19, from outside its reach.
  @towers_per_trebuchet 2
  @max_trebuchets 6
  # A wave with Trebuchets shells the towers by its target before the rest goes in (`release/4`):
  # towers within `@siege_clear` of the target, for at most `@siege_ticks`.
  @siege_clear 10
  # ...for as long as they keep bringing towers down: `@siege_idle` ticks without one falling and
  # everyone goes in (two Trebuchets need about 55 ticks a tower). Two stood idle 9 tiles from a
  # tower for 200 ticks once, with the wave waiting behind them and no enemy fighter left.
  @siege_idle 90
  # A siege party: with their army gone (what we have at the rally point is `@margin` times the
  # fighters of theirs we know of, none included), the Trebuchets there go out without waiting for
  # a wave's worth of attackers, one of them or more, with whoever is there for an escort. They
  # outrange every tower, so towers don't count against a party, to leave or to be called back,
  # and it isn't called back for being few. Two stood at the rally point for 650 ticks in a game
  # lost by 886 points, facing no fighters, six towers and four Command Centers.
  # A party also goes hunting with their army alive, at a base of theirs it isn't at
  # (`soft_target/4`): a drop-off of theirs with no fighters of theirs we know of within
  # `@hunt_clear` that the escort (`@hunt_escort` attackers or more) couldn't meet. Their workers
  # stand a dozen and more to a tile by their drop-offs, mostly with no Soldier near.
  @hunt_clear 12
  @hunt_escort 4
  @hunt_known 0.5
  # A base of a boom's is open to an attack with this many finished towers of theirs or fewer
  # within `@open_cover` of it (a tower reaches 5; two more for where ours stand to hit it), and it
  # is gone for with this many attackers or more.
  @open_towers 2
  @open_cover 7
  @open_min 8
  # Trebuchets needed at the rally point to go out with a wave.
  @siege_group 2
  # A wave with siege waits this far short of the target for it, at most `@siege_wait` ticks.
  @staging_distance 9
  @staging_clear 3
  @siege_wait 60

  # How far from the Command Center a tower goes: a tower hits 5 tiles out, so from here it covers
  # the Command Center, the ore line and the guards.
  @tower_ring 3..4

  # {building, how many we want, workers we need first, where it goes}, built one at a time.
  # The depot by the home ore comes first of all, at tick 0, with `@first_depot_builders`: miners
  # bank without the walk to the Command Center from the start. (It used to wait for 9 workers, and
  # if the Barracks finished first, for the army floor and the reserve too: up at tick 199 once.)
  # No Guard Tower before tick `@tower_from`: the bots that tower up first mostly lose, the ones
  # that win build theirs after the economy is going, and end with 7 to 10 (`@extras`).
  # The second Command Center is the backup: built far from every base (`:hideout`), so that losing
  # the main one doesn't eliminate us (a player is out only with no Command Center at all), which
  # would also wipe our survival score. Rebuilt if lost.
  # The backup Command Center comes last, once the rest is up and we have 10 fighters: early on
  # it is 400 ore while the first raids come, and with few players nobody is about to wipe us out.
  # Three Barracks before the first tower and a fourth with it: the hardest house bot has four by
  # tick 200 and 19 fighters to our 8, with the same workers.
  @build_order [
    {"ResourceDepot", 1, 0, :ore},
    {"Barracks", 1, 7, :base},
    {"TechLab", 1, 10, :base},
    {"Barracks", 2, 15, :base},
    {"Barracks", 3, 19, :base},
    {"GuardTower", 1, 21, :front},
    {"Barracks", 4, 25, :base},
    {"GuardTower", 2, 25, :front},
    {"CommandCenter", 2, 17, :hideout, 10}
  ]

  # In a big game: three Barracks early to mass-produce, a square of `@big_towers` towers around
  # the whole base (`:square`), and no first wave until it is up. The army comes first: an entry's
  # optional fifth number is the fighters we must have before it is built (the backup Command
  # Center at 10, the rest of the square at 15), so the ore goes into soldiers until then.
  @big_build_order [
                     {"ResourceDepot", 1, 0, :ore},
                     {"Barracks", 1, 7, :base},
                     {"GuardTower", 1, 10, :square},
                     {"Barracks", 2, 12, :base},
                     {"TechLab", 1, 10, :base},
                     {"GuardTower", 2, 14, :square},
                     {"Barracks", 3, 16, :base},
                     {"GuardTower", 3, 16, :square},
                     {"CommandCenter", 2, 16, :hideout, 10}
                   ] ++ for(n <- 4..10, do: {"GuardTower", n, 20, :square, 15})
  @big_towers 10

  # A medium game (6 to 9 players, see `medium?/1`): a tower facing each neighbor and two more (4 in
  # all, not 10), three Barracks, and the backup Command Center last, at 20 fighters. The ore goes
  # into the army: the first wave at `@medium_first_wave`, at the weaker neighbor.
  @medium_build_order [
                        {"ResourceDepot", 1, 0, :ore},
                        {"Barracks", 1, 7, :base},
                        {"GuardTower", 1, 10, :front},
                        {"GuardTower", 2, 11, :front},
                        {"Barracks", 2, 12, :base},
                        {"TechLab", 1, 10, :base},
                        {"Barracks", 3, 15, :base},
                        {"GuardTower", 3, 16, :front},
                        {"GuardTower", 4, 18, :front},
                        {"CommandCenter", 2, 18, :hideout, 20}
                      ]
  @huge_game 10
  # The ore of an eliminated neighbor: deposits this close to where it started.
  @conquest_reach 10
  @medium_first_wave 15

  @needs_barracks ["GuardTower", "TechLab"]

  # Home is short of ore when the ore left near our drop-offs is under `@low_home_ore`, early enough
  # that the next depot is up before the ore runs out (workers stack
  # on a deposit, so how many there are says nothing about running out). Short for `@short_for_ticks` in a
  # row, a Resource Depot goes by the closest other ore, ahead of the build order.
  @low_home_ore 3000
  # A Guard Tower this close to an outpost counts as its tower.
  @outpost_tower_reach 6
  # Towers an outpost gets once we are rich.
  @outpost_towers 2
  # Where we lost a building, no new depot for this long: it was a contested spot.
  @avoid_lost_ticks 300
  # Workers mining one far field (no drop-off within reach) that get a depot by it right away.
  @remote_miners 3
  # A field whose walk to a drop-off is longer than this gets a depot by it (see `remote_depot/3`).
  @depot_walk 2
  # ...and has at least this much ore left: a depot (100) by a field about to run dry is wasted (one
  # went up by 342 ore that ran out two ticks later, leaving us 101, short of the next one).
  @depot_ore 1000
  # A depot is built by up to this many of the workers who will use it; the first Barracks by this
  # many (see `builders/4`).
  @depot_builders 5
  @first_barracks_builders 3
  @first_lab_builders 2
  @short_for_ticks 30
  # ...or under this much for each worker: a bigger workforce empties the fields sooner.
  @low_ore_per_worker 150
  # A field worth a new depot away from home has at least this much ore left.
  @expansion_ore 400
  # Building that keeps failing at a spot away from home (`strike/4`): the order failed or its
  # builder died, a worker had to be sent to an abandoned site again, or what stood there was
  # destroyed (that counts double). At `@site_strikes` in `@avoid_lost_ticks` ticks the spot is
  # blocked: no worker is sent to the site, nothing new goes up within `@blocked_radius` of it, and
  # the next depot goes by another field. A depot site under a tower we couldn't see was started
  # six times in 80 ticks; a backup Command Center had a worker sent to it eight times.
  @site_strikes 3
  @blocked_radius 2
  # The survey for ore (see `survey/3`): rings this far around the Command Center, and how long the
  # scout tries for one spot.
  @survey_rings [10, 20]
  @survey_timeout 40
  # Once home runs short of ore, the survey goes on over the whole map, on a grid this many tiles
  # apart (a scout sees 8, so it sees the ore between two spots), and at eliminated players' starts.
  @far_grid 12
  # Ore kept back for workers (two of them), and how few workers make training them come first.
  @worker_reserve 100
  # The opening: with no Barracks up yet, before this tick, no ore is kept back.
  @opening_ticks 300
  @rebuild_workers 5

  # Each tier comes after the one before it (`@research_needs`), and a TechLab researches one at a
  # time. Fortify: +1 armor for every finished building (towers, outposts) each tier.
  # Every tier of Weapons (units and towers), Armor (units) and Fortify (buildings, towers too),
  # the fighting ones before the second Harvesting. One TechLab got through five of these in a
  # 630-tick game (each takes 30 to 80 ticks, one at a time): a second one (`@second_lab_workers`)
  # researches alongside it.
  # Armor before SiegeEngineering: the house bots end with Armor3, and in two games of three we
  # stopped at Armor1. On the game's engine, 30 Soldiers with Armor3 beat 30 with Armor1 (both
  # with Weapons2) four times in five, with 7 left.
  # Both Harvestings first: each is one more ore a mining tick (2, then 3, then 4) for every worker
  # we ever have. The house bots had the first at ticks 122 and 128 and we at 164, and for those
  # 40 ticks they mined 750 to 860 ore in 20 ticks to our 510 on the same workers; the second they
  # had at tick 251, and we after all the Weapons, the Armor and SiegeEngineering.
  @research ["Harvesting1", "Harvesting2", "Weapons1", "Armor1", "Armor2", "Weapons2", "Armor3", "SiegeEngineering", "Fortify1", "Fortify2"]
  @research_first ["Harvesting1", "Harvesting2", "Weapons1", "Armor1", "Armor2", "Weapons2", "Armor3"]
  @research_needs %{"Harvesting2" => "Harvesting1", "Weapons2" => "Weapons1", "Armor2" => "Armor1", "Armor3" => "Armor2", "Fortify2" => "Fortify1"}

  @type pos :: {integer, integer}

  # `mode` is only a summary for the logs; units go by the rest. `why` explains this tick's army
  # decisions, [{kind, text}], for the decision log (`Swarm.Decisions`); units ignore it.
  @type strategy :: %{
          mode: :gather | :attack | :defend,
          target: pos() | nil,
          rally: pos() | nil,
          post: pos() | nil,
          threat: Roles.threat(),
          wave: Roles.wave(),
          why: [{atom(), String.t()}],
          hold: String.t() | nil,
          look: pos() | nil,
          serum: :take | nil,
          raze: integer() | nil,
          check: %{integer() => pos()},
          fall_back: boolean(),
          spare: spare() | nil,
          survey: pos() | nil,
          regroup: pos() | nil,
          peek: pos() | nil,
          help: pos() | nil
        }

  # The last opponent's Command Center, left standing (`spare/3`): its id and where it is;
  # `goal`, where the wave goes (their nearest other building, else `camp`); `camp`, where the
  # army waits by it, out of its own reach; `siege_camp`, the same for Trebuchets; `farm`, whether
  # they are down to it (nothing else of theirs could be another one), so their side of the map
  # is ours to mine.
  @type spare :: %{id: integer(), pos: pos(), goal: pos(), camp: pos(), siege_camp: pos(), farm: boolean()}

  # `wave` is the wave that is out: %{id, members}. `next_wave` is the next one's id.
  # `enemies` is enemy fighter id => how it looked when last seen (with "seen", the tick).
  # `pending` is the building we ordered and are waiting to see: %{type, builder, at, had}.
  # `helpers` is building id => {worker id, tick} for workers sent to finish abandoned sites.
  # `ore_short_since` is the tick home has been short of ore since, or nil.
  # `recalled_at` is the last tick a wave was called home to defend, or nil.
  # `look` is the last look at a target: %{owner, pos, at: when we sent the scout, done: when it
  # got there (or we gave up), or nil}, or nil.
  # `raid` is the raid going on or just over: %{at: last tick it was here, kills: its fighters we
  # killed at home}, or nil.
  # `buildings` is our building id => where it stands; `lost` is spot => tick, for buildings that
  # went missing (destroyed) in the last `@avoid_lost_ticks`.
  def new_memory do
    %{
      wave: nil,
      next_wave: 1,
      enemies: %{},
      pending: nil,
      helpers: %{},
      ore_short_since: nil,
      buildings: %{},
      lost: %{},
      # spot => the ticks building failed there lately (see `@site_strikes`).
      strikes: %{},
      # The ore the map started with (`map_ore/2`), once we have seen our home piles; our banked
      # ore the last time it grew and when, {ore, tick}; and whether there was nothing left to mine
      # last tick, for logging the change.
      map_ore: nil,
      income_at: {0, 0},
      mined_out: false,
      # The search for ore while stalled (`ore_search/3`): worker id => %{pos, at}; the places
      # looked at (or given up on); and whether there is nowhere left to look.
      search: %{},
      searched: [],
      search_done: false,
      # Where we have ordered base Command Centers (`base_cc/3`), and the one on its way:
      # %{site, builders, at} until it breaks ground (or fails), or nil. It has its own slot:
      # `pending` and the rest of the building carry on while its builders walk.
      bases: [],
      base_order: nil,
      # The extra Barracks on its way (`more_barracks/3`), like `pending`, or nil.
      barracks_order: nil,
      # Every deposit we have ever seen: where => the most ore we saw in it (for `inferred_ore/2`),
      # and the mirrored spots we have seen with no ore on them.
      layout: %{},
      no_ore: [],
      # Fields worth a base (where their first pile is) => the tick we last had it in sight.
      checked: %{},
      # player => {the most of their army we have known lately (`Roles.strength/1`), the tick}.
      army_seen: %{},
      # What kind of opponent each player is (`Swarm.Reads`), by slot.
      reads: %{},
      # Whether the army keeps together at home (`@together_until`).
      together: false,
      # Opponents' starts we have seen with no Command Center of theirs on them (see `last_cc/2`).
      empty_starts: [],
      # The spots blocked last tick, for logging each once.
      blocked: [],
      recalled_at: nil,
      raid: nil,
      look: nil,
      # Our buildings' HP last tick (to notice one being hit), and the check going on around one
      # hit by something we can't see: %{building, pos, at, checkers: unit id => spot, found}.
      hp: %{},
      check: nil,
      # When the last strike at a tower came back (see `@strike_rest`), or nil.
      strike_back_at: nil,
      # The serum: nil (not taken yet), :off (not in this game), :spent, or {:until, last tick}.
      # Taken by the game loop when the strategy asks for it (`strategy.serum`).
      serum: nil,
      # Every deposit we have seen and haven't seen gone: id => it as last seen, with "seen" (see
      # `see/2`).
      ore: %{},
      # The survey of our side for ore (see `survey/3`): spots looked at, and the one the scout is
      # on, %{pos, at}, or nil.
      surveyed: [],
      survey: nil,
      # Whether home was falling back to the towers last tick (`Roles.fall_back?/2`), and the last
      # tick it had reason to (it holds `@fall_back_hold` ticks past that).
      fall_back: false,
      fall_back_at: nil,
      # Each fight's call last tick (`Roles.call/1`), by group id, for the decision log; and the
      # ids of the enemy fighters in the fights we were going into (`View.going_in`).
      fights: %{},
      going_in: [],
      # ...and in the fights we were staying out of (`View.staying_out`).
      staying_out: [],
      # Regrouping at the backup Command Center while the main base is overrun: %{pos, at: the last
      # tick it was}, or nil (see `regroup/2`).
      regroup: nil,
      # The look where a checker died (see `peek/3`), %{pos, at} or nil, and the tick before which
      # no new check starts (`@check_rest` after a checker dies), or nil.
      peek: nil,
      check_rest: nil,
      # The last tick a wave was called home for an enemy army near home (`army_near_home/3`).
      army_recalled_at: nil,
      # After a wave took its player out: when it was called home, and whether the next wave waits
      # for a fresh look at its target (see `launch/6`).
      came_home_at: nil,
      check_next: false,
      # Where home's attackers are helping, %{pos, clear_since}, or nil, and the tick help was
      # last called off (see `help/3`).
      help: nil,
      help_off_at: nil,
      help_off_pos: nil,
      # The tick the army living at a forward base was last called home (`home_call/3`), or nil.
      home_call: nil,
      # The last opponent's Command Center we leave standing ({its id, farm}, for logging each once),
      # and whether that was given up for this match (their army came back; see `spare/3`).
      spared: nil,
      spare_lifted: false,
      # Enemy towers we never saw that shot at us (`towerShots`), id => as a remembered building,
      # until we see the spot without them (see `see/2`).
      shot_towers: %{},
      # Safe mode: the spare is over and the wave goes straight for that Command Center, called home
      # by nothing (%{owner, id, pos}, see `spare/3`), or nil.
      kill: nil
    }
  end

  @doc """
  Remembers the ore: every deposit in sight as it is now, and forgets one we should see where it
  was and don't (mined out). Returns the view with the remembered ones added to its deposits
  (`View.with_known_ore/2`), for the brain and the units alike, and the memory.
  """
  @spec see(View.t(), map() | nil) :: {View.t(), map()}
  def see(%View{} = v, memory) do
    memory = new_memory() |> Map.merge(memory || %{}) |> Map.take(Map.keys(new_memory()))

    seen = for d <- v.deposits, into: %{}, do: {d["id"], d |> Map.take(["id", "x", "y", "remaining"]) |> Map.put("seen", v.tick)}

    ore =
      memory.ore
      |> Map.reject(fn {id, d} -> not Map.has_key?(seen, id) and View.in_sight?(v, View.pos(d)) end)
      |> Map.merge(seen)

    v = %{v | regroup: memory.regroup && memory.regroup.pos, recent_enemies: recent_enemies(v, memory.enemies), together: memory.together, bases: memory.bases, going_in: MapSet.new(memory.going_in), staying_out: MapSet.new(Map.get(memory, :staying_out, [])), serum_on: match?({:until, last} when last >= v.tick, memory.serum)}
    shot_towers = shot_towers(v, memory.shot_towers)
    v = %{v | remembered: v.remembered ++ Map.values(shot_towers)}
    {View.with_known_ore(v, ore), %{memory | ore: ore, shot_towers: shot_towers}}
  end

  # An enemy tower that shot at us from the fog (`towerShots` names it and where it stands) is
  # known from then on, like one we saw, so we keep out of its reach. Forgotten once the server
  # has it (in sight, or remembered), or we see the spot and it isn't there (destroyed).
  defp shot_towers(%View{} = v, known) do
    shot =
      for s <- v.tower_shots, s["owner"] != v.me, into: %{} do
        {s["towerId"],
         %{"id" => s["towerId"], "type" => "GuardTower", "owner" => s["owner"], "x" => s["fromX"], "y" => s["fromY"], "hp" => 500, "completed" => true, "seen" => v.tick}}
      end

    listed = MapSet.new(v.enemy_buildings ++ v.remembered, & &1["id"])

    known
    |> Map.merge(shot)
    |> Map.reject(fn {id, t} -> MapSet.member?(listed, id) or (not Map.has_key?(shot, id) and View.in_sight?(v, View.pos(t))) end)
  end

  # Enemy fighters out of sight now that we saw in the last `@recent_enemy_ticks` ticks, where we
  # last saw them; not ones whose spot we can see (they moved on). A soldier stepping toward a lone
  # enemy saw an archer pack come into sight, pulled back, lost sight of it, found the odds good
  # again and stepped in, every tick: the pack still counts for a few ticks after it goes out of sight.
  defp recent_enemies(%View{} = v, enemies) do
    visible = MapSet.new(v.enemy_units, & &1["id"])

    for {id, e} <- enemies,
        not MapSet.member?(visible, id),
        v.tick - e["seen"] <= @recent_enemy_ticks,
        not View.in_sight?(v, View.pos(e)),
        do: e
  end

  @doc """
  Forgets deposits the server says are gone (a Gather on one was rejected: mined out where we
  couldn't see it). Workers that picked one pick other ore next tick.
  """
  def forget_ore(memory, []), do: memory
  def forget_ore(memory, ids), do: %{memory | ore: Map.drop(memory.ore, ids)}

  # The survey: a scout goes round our side of the map looking for ore, spot by spot (`survey_spots/2`),
  # so we know where to go when the ore by our drop-offs runs out or the enemy sits on it. A spot
  # is done once anything of ours sees it, or after `@survey_timeout` ticks of trying (a scout
  # can't get there). Each spot once a game: the ore is remembered, and it doesn't move.
  # Returns {the spot the scout should go to, or nil; memory; notes for the decision log}.
  defp survey(%View{cc: nil}, memory, _terrain), do: {nil, memory, []}

  defp survey(%View{} = v, memory, terrain) do
    # Short of ore at home: the rest of the map too (`far_spots/2`), the eliminated players'
    # starts first: their ore is untouched, and nothing else looks there.
    far = if memory.ore_short_since != nil, do: far_spots(v, terrain), else: []
    first = for p <- far, Enum.any?(v.fallen_starts, &(View.dist(&1, p) <= 3)), do: p
    spots = Enum.uniq(survey_spots(v, terrain) ++ far)
    seen = for p <- spots, p not in memory.surveyed, View.in_sight?(v, p), do: p
    surveyed = memory.surveyed ++ seen

    current =
      case memory.survey do
        %{pos: pos, at: at} = current -> if pos in surveyed or v.tick - at > @survey_timeout, do: nil, else: current
        nil -> nil
      end

    # (A field for a base is looked at again and again: never done.)
    surveyed = if memory.survey != nil and current == nil and memory.survey.pos not in Map.keys(memory.checked), do: Enum.uniq([memory.survey.pos | surveyed]), else: surveyed
    left = Enum.reject(spots, &(&1 in surveyed))
    scout = surveyor(v)

    # The best field for our next base (`base_candidates/2`), not looked at in the last `@recheck`
    # ticks: the scout goes (back) there first, to see whether it is clear. A base only goes where
    # we have seen the ground lately: an eliminated player's start, a corner whose ore we only
    # infer, anywhere.
    fields = if base_wanted?(v, memory), do: base_candidates(v, memory), else: []
    best = fields |> Enum.map(&View.pos(hd(&1))) |> List.first()
    due? = best != nil and (memory.checked[best] == nil or v.tick - memory.checked[best] >= @recheck)
    recheck = if due?, do: best
    watched = Map.keys(memory.checked)
    checking? = current != nil and current.pos in watched

    {current, notes} =
      cond do
        scout != nil and recheck != nil and not checking? ->
          {%{pos: recheck, at: v.tick}, [{:survey, "scout #{scout["id"]} looking at the field by #{fmt(recheck)}: is it clear for a base?"}]}

        current != nil ->
          {current, []}

        scout == nil or left == [] ->
          done = if memory.survey && left == [], do: [{:survey, "survey done: #{map_size(memory.ore)} deposits known"}], else: []
          {nil, done}

        true ->
          next = Enum.min_by(left, &{&1 not in first, View.dist(&1, View.pos(scout)), &1})
          {%{pos: next, at: v.tick}, [{:survey, "scout #{scout["id"]} looking for ore at #{fmt(next)}, #{length(left)} spots left"}]}
      end

    {current && current.pos, %{memory | surveyed: surveyed, survey: current}, notes}
  end

  # The main base is overrun: enemy fighters inside it at least `@overrun_margin` times all of home
  # (`Roles.all_home_strength/3`, our towers there included), and we have a finished backup Command
  # Center. Then we regroup there (`strategy.regroup`), in secret: it trains its own
  # `@backup_workers` workers, who mine by it and never lead anyone to it (`Swarm.UnitBrain`);
  # nobody else goes there, and no wave leaves. Over `@regroup_hold` ticks after the base was last
  # overrun.
  # Returns {where we regroup or nil, memory, notes for the decision log}.
  defp regroup(%View{cc: nil}, memory), do: {nil, %{memory | regroup: nil}, []}

  defp regroup(v, memory) do
    home = View.pos(v.cc)
    backup = backup_cc(v)
    inside = Enum.filter(v.enemy_units, &(&1["type"] != "Worker" and View.dist(View.pos(&1), home) <= @base_radius))
    {theirs, ours} = {Roles.strength(inside), Roles.all_home_strength(v, memory.wave, inside)}
    overrun? = backup != nil and inside != [] and theirs >= @overrun_margin * ours

    regroup =
      cond do
        overrun? -> %{pos: View.pos(backup), at: v.tick}
        memory.regroup && backup && v.tick - memory.regroup.at < @regroup_hold -> memory.regroup
        true -> nil
      end

    notes =
      case {memory.regroup, regroup} do
        {nil, %{pos: pos}} ->
          [{:regroup, "main base overrun, strength #{round(theirs)} vs #{round(ours)} at home: regrouping at the backup Command Center #{fmt(pos)}"}]

        {%{}, nil} ->
          [{:regroup, "regroup over: back to the main base"}]

        _ ->
          []
      end

    {regroup && regroup.pos, %{memory | regroup: regroup}, notes}
  end

  # Where home's attackers help (`strategy.help`): one decision for all of them, kept from tick to
  # tick, so they don't turn back every time an archer steps out of sight. Help is wanted at an
  # outpost, by our workers or at a siege (`Roles.help_wanted/1`, not under an enemy tower).
  #
  # - Committed: it follows the fight (the wanted spot closest to where it was, within
  #   `@help_follow`), and holds while there is one. It ends once nothing has been wanted there for
  #   `@help_clear` ticks, or when what is there is `@help_give_up` times what home can bring.
  # - Not committed: it commits to the wanted spot closest to the rally point that home can take
  #   (`Roles.can_take?/3`), so everyone goes together, from the rally point; not within
  #   `@help_rest` ticks of calling help off.
  #
  # A raid on the main base still comes first for the units (`Swarm.UnitBrain`).
  # Returns {where, or nil; memory; notes for the decision log}.
  defp help(%View{cc: nil}, memory, _s), do: {nil, %{memory | help: nil}, []}

  defp help(v, memory, s) do
    spots = Roles.help_wanted(v) |> Enum.reject(&Roles.covered?(v, &1)) |> Enum.filter(&worth_help?(v, &1))

    resting? = memory.help_off_at != nil and v.tick - memory.help_off_at < @help_rest

    case memory.help do
      nil when resting? ->
        {nil, memory, []}

      nil ->
        case spots |> Enum.filter(&may_help?(v, memory, s, &1)) |> Enum.min_by(&{View.dist(&1, s.rally || &1), &1}, fn -> nil end) do
          nil -> {nil, memory, []}
          spot -> {spot, %{memory | help: %{pos: spot, from: spot, clear_since: nil}}, [{:help, "home goes to help at #{fmt(spot)}"}]}
        end

      %{pos: pos} = help ->
        near = Enum.filter(spots, &(View.dist(&1, pos) <= @help_follow))
        # It follows the fight only to where home can still take what is there: following onto
        # the middle of the pack had it called off the next tick, and committed again at its edge.
        # And no farther from home than `@help_chase` past where it committed: after two Soldiers
        # by a depot halfway to a neighbor it went eight tiles on, to their base, and led 53 home.
        home = View.pos(v.cc)
        leash = View.dist(Map.get(help, :from, pos), home) + @help_chase
        takeable = Enum.filter(near, &(View.dist(&1, home) <= leash and Roles.can_take?(v, s.wave, &1)))
        pos = Enum.min_by(takeable, &{View.dist(&1, pos), &1}, fn -> pos end)
        clear_since = if near == [], do: help.clear_since || v.tick, else: nil
        # The same measure that committed to it (`Roles.help_odds/3`).
        {ours, theirs} = Roles.help_odds(v, s.wave, pos)

        cond do
          clear_since && v.tick - clear_since >= @help_clear ->
            {nil, %{memory | help: nil}, [{:help, "help at #{fmt(pos)} over: nothing there for #{@help_clear} ticks"}]}

          theirs > @help_give_up * ours ->
            why = "help at #{fmt(pos)} called off: #{round(theirs)} there against #{round(ours)} home can bring"
            {nil, %{memory | help: nil, help_off_at: v.tick, help_off_pos: pos}, [{:help, why}]}

          true ->
            {pos, %{memory | help: %{help | pos: pos, clear_since: clear_since}}, []}
        end
    end
  end

  # In every game (it was only with two or more opponents in; one on one, 61 of ours went out to a
  # depot in the middle 20 tiles from our nearest tower, and 87 died for 28), the army only goes
  # out to fight under our towers: a spot within
  # reach of a finished Guard Tower of ours (its range plus one), or within `@help_cover` of a
  # Command Center of ours. A depot with no tower is the price of a Soldier; 38 went out for one in
  # the middle, met 40, and led them home. And six tiles from a tower is the open: 32 fighters and
  # 62 workers died at a field between two of our bases, in reach of neither's towers.
  defp worth_help?(v, spot) do
    Enum.any?(Roles.our_towers(v), &(View.dist(View.pos(&1), spot) <= Roles.range(&1) + 1)) or
      Enum.any?(View.buildings_of(v, "CommandCenter"), &(View.dist(View.pos(&1), spot) <= @help_cover))
  end

  # Whether home may commit to help at `spot`: it can take what is there (`Roles.can_take?/3`);
  # near where help was last called off (within `@help_follow`, for `@help_memory` ticks), only
  # clearly, at `@help_give_up` times what is there, the margin it was called off at: committing at
  # even next to the same pack had it walk out, see the pack, call off, and again every 20 ticks.
  defp may_help?(v, memory, s, spot) do
    near_last? =
      memory.help_off_pos != nil and memory.help_off_at != nil and v.tick - memory.help_off_at < @help_memory and
        View.dist(spot, memory.help_off_pos) <= @help_follow

    {ours, theirs} = Roles.help_odds(v, s.wave, spot)
    # To commit, what is there counts for at least the most we have known lately of the army of
    # whoever is there (`army_seen/3`): two raiders in sight had home walk out into the forty
    # behind them. Staying is still judged on what is there (`help/3`), so it doesn't flip.
    owners = for e <- v.enemy_units, e["type"] != "Worker", View.dist(View.pos(e), spot) <= @help_follow, uniq: true, do: e["owner"]
    lately = owners |> Enum.map(&elem(Map.get(memory.army_seen, &1, {0, 0}), 0)) |> Enum.max(fn -> 0 end)
    # With two or more opponents in, also for their army by the scoreboard (`army_by_score/2`), a
    # look or none: nobody had looked at the neighbor whose two Soldiers drew 32 of ours out to 50.
    by_score = if map_size(v.start_owner) >= 2, do: owners |> Enum.map(&army_by_score(v, &1)) |> Enum.max(fn -> 0 end), else: 0
    theirs = max(theirs, by_score)
    theirs = max(theirs, lately)
    if near_last?, do: ours >= @help_give_up * theirs, else: ours >= theirs
  end

  # Our finished Command Center that isn't the main one, or nil.
  defp backup_cc(v) do
    v
    |> View.buildings_of("CommandCenter")
    |> Enum.find(&(&1["completed"] and &1["id"] != v.cc["id"]))
  end

  # The scout that surveys: the first by id (`Swarm.UnitBrain` gives it the same job).
  defp surveyor(v), do: v |> View.units_of("Scout") |> Enum.min_by(& &1["id"], fn -> nil end)

  # Spots to look at for ore: rings around the Command Center (`@survey_rings`, at their corners
  # and the middle of each side; the outer ring also halfway between), on our side of the map, on
  # open ground (the nearest open tile within 3), and inside the map.
  defp survey_spots(%View{cc: cc} = v, terrain) do
    {cx, cy} = View.pos(cc)
    rows = List.to_tuple(terrain)

    open? = fn {x, y} ->
      y in 0..(tuple_size(rows) - 1)//1 and x in 0..(byte_size(elem(rows, y)) - 1)//1 and :binary.at(elem(rows, y), x) == ?.
    end

    for r <- @survey_rings,
        steps = if(r >= 20, do: [-2, -1, 0, 1, 2], else: [-2, 0, 2]),
        i <- steps,
        j <- steps,
        abs(i) == 2 or abs(j) == 2,
        {x, y} = {clamp(cx + div(i * r, 2), v.map_width), clamp(cy + div(j * r, 2), v.map_height)},
        View.ours?(v, {x, y}),
        spot = Enum.find(for(d <- 0..3, dx <- -d..d, dy <- -d..d, do: {x + dx, y + dy}), open?),
        spot != nil,
        uniq: true,
        do: spot
  end

  # Spots to look at for ore once home runs short, anywhere on our side of the map or clear of
  # every enemy base (`View.claimable?/2`; all of it with the last opponent spared, see `plan/3`):
  # every eliminated player's start, and a grid
  # `@far_grid` tiles apart, on open ground (the nearest open tile within 3).
  defp far_spots(%View{} = v, terrain) do
    rows = List.to_tuple(terrain)

    open? = fn {x, y} ->
      y in 0..(tuple_size(rows) - 1)//1 and x in 0..(byte_size(elem(rows, y)) - 1)//1 and :binary.at(elem(rows, y), x) == ?.
    end

    half = div(@far_grid, 2)
    grid = for x <- half..(v.map_width - 1)//@far_grid, y <- half..(v.map_height - 1)//@far_grid, do: {x, y}

    for {x, y} <- v.fallen_starts ++ grid,
        View.claimable?(v, {x, y}),
        spot = Enum.find(for(d <- 0..3, dx <- -d..d, dy <- -d..d, do: {x + dx, y + dy}), open?),
        spot != nil,
        uniq: true,
        do: spot
  end

  @spec plan(View.t(), map(), [String.t()]) :: {strategy(), [map()], map()}
  def plan(%View{} = v, memory, terrain) do
    # Memory from an older version may have other keys: keep only the ones we know.
    memory = new_memory() |> Map.merge(memory || %{}) |> Map.take(Map.keys(new_memory()))
    memory = %{memory | map_ore: memory.map_ore || map_ore(v, memory), income_at: income_at(memory, v)}
    {no_ore, ore_note} = nothing_to_mine(v, memory)
    memory = %{memory | mined_out: no_ore != false}
    # Stalled with nowhere left to look (as of last tick's search): `:nowhere`.
    v = %{v | no_ore: if(no_ore == :stalled and memory.search_done, do: :nowhere, else: no_ore)}
    before = memory.enemies
    memory = %{memory | raid: raid(memory, v), enemies: remember_enemies(memory.enemies, v)}
    memory = %{memory | army_seen: army_seen(memory, v, before)}
    memory = %{memory | together: together?(memory, v)}
    v = %{v | together: memory.together, bases: memory.bases}
    {strategy, memory} = strategy(v, memory)
    # With the last opponent down to the Command Center we spare, their side of the map is ours
    # too: its ore is looked for and taken like ours. Their start counted as enemy ground left 30
    # workers idle for the last 600 ticks of a game, with 20,000 ore on the map. Not while the rest
    # of their base still stands: no depots by their towers.
    v = if match?(%{farm: true}, Map.get(strategy, :spare)), do: %{v | enemy_starts: []}, else: v
    # And no tower of ours goes up in its reach: towers shoot buildings too, once no unit is near.
    v = %{v | spared: Map.get(strategy, :spare) && strategy.spare.pos}
    memory = remember_layout(memory, v)
    {survey, memory, surveyed} = survey(v, memory, terrain)
    {regroup, memory, regrouped} = regroup(v, memory)
    {help, memory, helped} = help(v, memory, strategy)
    {search, memory, searching} = ore_search(v, memory, terrain, Map.get(strategy, :worker_scout))

    strategy =
      %{strategy | survey: survey, regroup: regroup, help: help, why: ore_note ++ strategy.why ++ surveyed ++ regrouped ++ helped ++ searching}
      |> Map.put(:search, search)
    memory = settle_pending(memory, v)
    memory = settle_base(memory, v)
    memory = settle_barracks(memory, v)
    memory = %{memory | ore_short_since: short_since(memory, v)}
    memory = remember_losses(memory, v)
    v = %{v | blocked: blocked(memory, v)}

    gave_up =
      for spot <- v.blocked -- memory.blocked,
          do: {:site_blocked, "building keeps failing at #{fmt(spot)}: nothing goes up there for #{@avoid_lost_ticks} ticks"}

    strategy = %{strategy | why: strategy.why ++ gave_up}
    memory = %{memory | blocked: v.blocked}

    # Ore for a couple of workers stays back from everything else once the army is being trained
    # (a Barracks is up, or past the opening: the Barracks may be gone): with every worker dead and
    # nothing banked, the economy never starts again. Not in the opening, where every bit of ore
    # goes into the first buildings.
    opening? = v.tick < @opening_ticks and not Enum.any?(View.buildings_of(v, "Barracks"), & &1["completed"])
    reserve = if opening?, do: 0, else: min(v.ore, @worker_reserve)
    # While the main base is raided or overrun, workers trained there only die: the reserve waits
    # for the backup's own workers (first claim on it) or for the raid to be gone.
    home_reserve = if Roles.threat(v) != nil or memory.regroup, do: 0, else: reserve

    bases_before = memory.bases
    # A base on its way: its 400 stays in the bank until its builders break ground.
    held = if memory.base_order, do: @costs["CommandCenter"], else: 0

    # Under the flood floor (`flood_floor/2`), the next Barracks comes right after the fighters,
    # ahead of everything else that is built (`more_barracks/4`).
    catch_up? = Roles.strength(Roles.fighters(v)) < flood_floor(v, memory)

    {commands, memory, _ore} =
      {[], memory, v.ore - reserve - held}
      |> with_reserve(reserve, &train_backup_workers(&1, v))
      |> rebuild_workers(v, home_reserve)
      |> finish_sites(v)
      |> research_first(v)
      |> first_base(v, terrain)
      |> army_floor(v, memory)
      |> then(&if(catch_up?, do: more_barracks(&1, v, terrain, true), else: &1))
      |> found_base(v, terrain)
      |> build(v, terrain)
      |> then(&if(catch_up?, do: &1, else: more_barracks(&1, v, terrain, false)))
      |> with_reserve(home_reserve, &train_workers(&1, v))
      |> research(v)
      |> train_scout(v)
      |> train_siege(v)
      |> train_army(v, terrain)

    founded = for spot <- memory.bases -- bases_before, do: {:base, "a Command Center of our own at #{fmt(spot)}: a base by that field"}
    strategy = %{strategy | why: strategy.why ++ founded}

    {strategy, Enum.reverse(commands), memory}
  end

  # The ore the map started with: by its layout (`@corner_ore` in each of four corners with two to
  # four players, `@ring_ore` a player on a ring), scaled by the biggest pile by our Command Center
  # (1,000 as a rule; a match can ask for more or less grubs). Nil until we see one.
  defp map_ore(%View{cc: nil}, _memory), do: nil

  defp map_ore(v, _memory) do
    home = View.pos(v.cc)
    piles = for d <- v.deposits, not Map.has_key?(d, "seen"), View.dist(View.pos(d), home) <= 8, do: d["remaining"] || 0

    case piles do
      [] -> nil
      _ -> round(if(v.players <= @mirror_players, do: 4 * @corner_ore, else: v.players * @ring_ore) * Enum.max(piles) / 1000)
    end
  end

  # Our banked ore the last time it grew, and when.
  defp income_at(%{income_at: {ore, _at}}, v) when v.my_mined > ore, do: {v.my_mined, v.tick}
  defp income_at(%{income_at: at}, _v), do: at

  # Whether there is nothing left for us to mine (see `@ore_dregs`), as {`:mined_out` (the map, for
  # certain), `:stalled` (we aren't getting any, whatever is left: we go and look for it,
  # `ore_search/3`) or false, what to log when it changes}. Never before `@stand_in_from`.
  defp nothing_to_mine(v, memory) do
    left = memory.map_ore && max(memory.map_ore - v.mined_all, 0)
    {_ore, grew_at} = memory.income_at
    workers = View.units_of(v, "Worker")
    mining? = Enum.any?(workers, &(&1["activity"] in ["Gathering", "Returning"]))

    {state, why} =
      cond do
        v.tick < @stand_in_from ->
          {false, nil}

        left != nil and left <= @ore_dregs * memory.map_ore ->
          {:mined_out, "the map is mined out: #{memory.map_ore} ore on it, #{v.mined_all} banked by everyone"}

        length(workers) >= @rebuild_workers and not mining? and v.tick - grew_at >= @ore_stall ->
          {:stalled,
           "we have banked nothing for #{v.tick - grew_at} ticks and nobody is mining" <>
             if(left, do: " (at most #{left} left on the map)", else: "")}

        true ->
          {false, nil}
      end

    note =
      cond do
        state == :mined_out and not memory.mined_out -> [{:economy, "nothing left to mine: #{why}. No more workers"}]
        state == :stalled and not memory.mined_out -> [{:economy, "#{why}: no more workers until we bank again, and we go looking for ore"}]
        state == false and memory.mined_out -> [{:economy, "mining again: workers are trained as usual"}]
        true -> []
      end

    {state, note}
  end

  # Stalled (`nothing_to_mine/2`), we go and find the ore: idle workers, up to `@searchers`, each
  # to the nearest place we haven't looked at that nobody else is going to. The places: where the
  # mirrored map says there is ore we haven't seen (`inferred_ore/2`), and a grid over the whole
  # map `@far_grid` apart (a worker sees 5 tiles), on open ground, where we may go: clear of every
  # living enemy's base (`View.claimable?/2`; all of it once the last one is down to the Command
  # Center we spare) and of their towers. A place is done once anything of ours sees it, or its
  # worker has had `@search_timeout` ticks. Ore found is ore known: the workers mine it and a
  # depot follows, as ever. Over when we bank again (the map mined out for certain needs no search).
  # Not the worker standing in for our scouts (`stand_in/1`): it has its own errand.
  # Returns {worker id => where to look, memory, what to log}.
  defp ore_search(%View{no_ore: no_ore} = v, memory, terrain, stand_in) when no_ore in [:stalled, :nowhere] do
    rows = List.to_tuple(terrain)

    open? = fn {x, y} ->
      y in 0..(tuple_size(rows) - 1)//1 and x in 0..(byte_size(elem(rows, y)) - 1)//1 and :binary.at(elem(rows, y), x) == ?.
    end

    half = div(@far_grid, 2)
    grid = for x <- half..(v.map_width - 1)//@far_grid, y <- half..(v.map_height - 1)//@far_grid, do: {x, y}
    inferred = memory |> inferred_ore(v) |> Enum.map(&View.pos/1)

    places =
      for {x, y} <- inferred ++ grid,
          View.claimable?(v, {x, y}) and not Roles.under_tower?(v, {x, y}),
          spot = Enum.find(for(d <- 0..3, dx <- -d..d, dy <- -d..d, do: {x + dx, y + dy}), open?),
          spot != nil,
          uniq: true,
          do: spot

    alive = MapSet.new(View.units_of(v, "Worker"), & &1["id"])
    timed_out = for {id, %{pos: pos, at: at}} <- memory.search, MapSet.member?(alive, id), v.tick - at > @search_timeout, do: pos
    seen = for p <- places, p not in memory.searched, View.in_sight?(v, p), do: p
    searched = Enum.uniq(memory.searched ++ seen ++ timed_out)
    left = Enum.reject(places, &(&1 in searched))

    # Workers keep the place they were given while it still wants looking at.
    kept = for {id, %{pos: pos} = job} <- memory.search, MapSet.member?(alive, id), id != stand_in, pos in left, into: %{}, do: {id, job}
    taken = MapSet.new(Map.values(kept), & &1.pos)

    free =
      v
      |> View.units_of("Worker")
      |> Enum.filter(&(&1["activity"] == "Idle" and &1["id"] != stand_in and not is_map_key(kept, &1["id"])))
      |> Enum.sort_by(& &1["id"])

    {jobs, _taken} =
      Enum.reduce(Enum.take(free, max(@searchers - map_size(kept), 0)), {kept, taken}, fn w, {jobs, taken} ->
        case left |> Enum.reject(&MapSet.member?(taken, &1)) |> Enum.min_by(&{View.dist(&1, View.pos(w)), &1}, fn -> nil end) do
          nil -> {jobs, taken}
          spot -> {Map.put(jobs, w["id"], %{pos: spot, at: v.tick}), MapSet.put(taken, spot)}
        end
      end)

    done? = left == []

    notes =
      cond do
        done? and not memory.search_done ->
          [{:economy, "looked for ore everywhere we may go (#{length(searched)} places): none to be had"}]

        memory.search == %{} and jobs != %{} ->
          [{:economy, "stalled: #{map_size(jobs)} worker(s) go looking for ore, #{length(left)} places we haven't seen"}]

        true ->
          []
      end

    {Map.new(jobs, fn {id, job} -> {id, job.pos} end), %{memory | search: jobs, searched: searched, search_done: done?}, notes}
  end

  # Banking (or the map mined out for certain): no search. What we looked at stays looked at.
  defp ore_search(_v, memory, _terrain, _stand_in), do: {%{}, %{memory | search: %{}, search_done: false}, []}

  # Every deposit we have ever seen, with the most ore we saw in it; when eliminated players'
  # starts were last in sight; and the spots where the mirrored map should have ore and we see none.
  defp remember_layout(memory, v) do
    layout =
      Enum.reduce(v.deposits, memory.layout, fn d, layout ->
        Map.update(layout, View.pos(d), d["remaining"] || 0, &max(&1, d["remaining"] || 0))
      end)

    # When each field worth a base (its first pile) was last in sight (`base_fields/2`).
    spots = v |> base_candidates(memory) |> Enum.map(&View.pos(hd(&1)))
    checked = for spot <- Enum.uniq(spots ++ Map.keys(memory.checked)), into: %{}, do: {spot, if(View.in_sight?(v, spot), do: v.tick, else: Map.get(memory.checked, spot))}
    known = MapSet.new(v.deposits, &View.pos/1)
    empty = for {pos, _ore} <- mirrored(layout, v), not MapSet.member?(known, pos), pos not in memory.no_ore, View.in_sight?(v, pos), do: pos

    %{memory | layout: layout, checked: checked, no_ore: memory.no_ore ++ Enum.uniq(empty)}
  end

  # The deposits the map's mirror symmetry says there are (two to four players: mirrored left to
  # right, top to bottom and both), as [{where, ore}], from every deposit we have seen.
  defp mirrored(layout, %View{players: players} = v) when players <= @mirror_players do
    {w, h} = {v.map_width - 1, v.map_height - 1}

    for {{x, y}, ore} <- layout, pos <- [{w - x, y}, {x, h - y}, {w - x, h - y}], not is_map_key(layout, pos), uniq: true, do: {pos, ore}
  end

  defp mirrored(_layout, _v), do: []

  # Deposits we haven't seen that the mirrored map should have (`mirrored/2`), as deposits without
  # an id worth naming (negative, so nobody is sent to gather one): for choosing where a base
  # goes. Not where we have looked and found none.
  defp inferred_ore(memory, v) do
    known = MapSet.new(v.deposits, &View.pos/1)

    memory.layout
    |> mirrored(v)
    |> Enum.reject(fn {pos, _ore} -> MapSet.member?(known, pos) or pos in memory.no_ore end)
    |> Enum.sort()
    |> Enum.with_index(1)
    |> Enum.map(fn {{{x, y}, ore}, i} -> %{"id" => -i, "x" => x, "y" => y, "remaining" => ore, "inferred" => true} end)
  end

  # No base left: everyone attacks.
  defp strategy(%View{cc: nil} = v, memory) do
    target = target_of(v, opponent(v, memory))
    {%{mode: :attack, target: target, rally: nil, post: nil, threat: nil, wave: nil, why: [], hold: nil, look: nil, serum: nil, raze: nil, check: %{},
       fall_back: false, spare: nil, kill: nil, survey: nil, regroup: nil, peek: nil, help: nil}, memory}
  end

  defp strategy(%View{} = v, memory) do
    {rally, memory, home_why} = home_call(v, memory, rally(v))
    threat = Roles.threat(v)
    # Any base under attack, outposts included, or our workers out in the field.
    attacked? = threat != nil or Roles.help_wanted(v) != []
    owner = opponent(v, memory)
    target = target_of(v, owner)
    # The last opponent's Command Center stays up (`spare/3`), the wave goes for the rest; or, in
    # safe mode (`memory.kill`), straight for it. Before the wave is kept or called home: safe mode
    # is what keeps it out.
    memory = forget_kill(v, memory)
    memory = %{memory | empty_starts: empty_starts(v, memory)}
    {spare, spare_why, memory} = spare(v, memory, memory.wave)
    killing? = memory.kill != nil
    # Called home to defend this tick (all in, or in safe mode, nothing comes home).
    home_recall? = memory.wave != nil and not all_in?(v) and not killing? and Roles.recall(v, memory.wave) != nil
    recalled_at = if home_recall?, do: v.tick, else: memory.recalled_at
    # Called home for an army near home: no new wave for `@calm_ticks` either, counterattack or
    # not: the army is still about, and a wave leaving into it was called straight back.
    army_recall? = memory.wave != nil and not all_in?(v) and not killing? and army_near_home(v, memory, memory.wave) != nil
    memory = if army_recall?, do: %{memory | army_recalled_at: v.tick}, else: memory
    calm? = recalled_at == nil or v.tick - recalled_at >= @calm_ticks
    stand_in = stand_in(v)
    {look, looked, counted} = look(memory, v, rally, owner, target, stand_in)
    memory = %{memory | army_seen: lower_count(memory.army_seen, counted, v)}
    {reads, read_why} = reads(v, memory, counted)
    memory = Map.put(memory, :reads, reads)
    {check, checked, died_at} = siege_watch(memory, v)
    {peek, peeked} = peek(memory, v, died_at)
    check_rest = if died_at, do: v.tick + @check_rest, else: memory.check_rest
    checked = checked ++ peeked
    memory = %{memory | look: look, check: check, peek: peek, check_rest: check_rest}
    memory_wave = memory.wave
    {wave, next_wave, why, hold} = wave(v, memory, rally, calm?, owner, target)
    # A raid answered with a counterattack is done with.
    raid = if memory.wave == nil and wave != nil, do: nil, else: memory.raid
    # A strike goes for its tower, a sortie for the siege; a sortie under way ends the check.
    target =
      case wave && Map.get(wave, :kind) do
        :strike -> wave.tower_pos
        :sortie -> wave.spot
        _ -> (wave && Map.get(wave, :goal)) || target
      end

    check = if wave && Map.get(wave, :kind) == :sortie, do: nil, else: memory.check

    target =
      cond do
        killing? -> memory.kill.pos
        spare -> spare.goal
        true -> target
      end

    why = read_why ++ home_why ++ spare_why ++ why

    strike_back_at =
      if memory_wave && Map.get(memory_wave, :kind) == :strike && wave == nil, do: v.tick, else: memory.strike_back_at

    # Home falls back to the towers when the raiders outside their reach are too strong for it.
    # It holds `@fall_back_hold` ticks past the last reason to: raiders stepping in and out of
    # sight would flip it every tick, and workers and defenders with it.
    fall_back_at = if Roles.fall_back?(v, wave), do: v.tick, else: memory.fall_back_at
    fall_back = fall_back_at != nil and v.tick - fall_back_at < @fall_back_hold
    why = why ++ fall_back_note(v, wave, fall_back, memory.fall_back)
    {fights, fight_why} = fight_notes(v, wave, Map.get(memory, :fights, %{}))
    # The fights we are going into, by their fighters, for next tick (`Roles.verdict/2`).
    going_in = for {_id, g} <- Roles.groups(v, wave).groups, g.size > 0, Roles.call(g) == :go, id <- g.ids, do: id
    staying_out = for {_id, g} <- Roles.groups(v, wave).groups, g.size > 0, Roles.call(g) == :away, id <- g.ids, do: id
    why = why ++ fight_why

    mode =
      cond do
        attacked? -> :defend
        wave -> :attack
        true -> :gather
      end

    strategy = %{
      mode: mode,
      target: target,
      rally: rally,
      post: post(v, rally, target),
      threat: threat,
      wave: wave,
      why: looked ++ checked ++ why,
      hold: hold,
      look: if(look && look.done == nil, do: look.pos),
      peek: peek && peek.pos,
      serum: if(memory.serum == nil and serum_moment?(v, memory_wave), do: :take),
      # While the serum lasts, Soldiers at home go in on a raid whatever its estimate says
      # (`Swarm.UnitBrain`): the estimate doesn't know they hit twice as hard.
      serum_on: match?({:until, last} when last >= v.tick, memory.serum) or (memory.serum == nil and serum_moment?(v, memory_wave)),
      raze: raze(v),
      check: if(check && check.found == nil, do: check.checkers, else: %{}),
      fall_back: fall_back,
      spare: spare,
      # Safe mode: the Command Center id every wave member goes for (`Swarm.UnitBrain`), or nil.
      kill: memory.kill && Map.take(memory.kill, [:id, :pos]),
      # The worker standing in for our scouts (`stand_in/1`), or nil.
      worker_scout: stand_in && stand_in["id"],
      survey: nil,
      regroup: nil,
      help: nil
    }

    # A wave called home because its player is out: the next one waits for it to be home
    # (`@calm_ticks`) and for a fresh look at its target.
    took_out = memory_wave != nil and wave == nil and wave_owner_out?(v, memory_wave)
    memory = if took_out, do: %{memory | came_home_at: v.tick, check_next: true}, else: memory
    memory = if wave != nil and memory_wave == nil, do: %{memory | check_next: false}, else: memory

    {strategy,
     %{
       memory
       | wave: wave,
         next_wave: next_wave,
         recalled_at: recalled_at,
         raid: raid,
         check: check,
         strike_back_at: strike_back_at,
         fall_back: fall_back,
         fall_back_at: fall_back_at,
         fights: fights,
         going_in: going_in,
         staying_out: staying_out
     }}
  end

  # A line for the decision log each time a fight's call changes (`Roles.call/1`): where, against
  # what, how many of ours, and the estimates behind it.
  defp fight_notes(v, wave, before) do
    %{groups: groups} = Roles.groups(v, wave)
    now = for {id, g} <- groups, Roles.notable?(g), into: %{}, do: {id, Roles.call(g)}

    notes =
      for {id, call} <- Enum.sort(now), Map.get(before, id) != call do
        g = groups[id]
        kinds = (v.enemy_units ++ v.recent_enemies) |> Enum.filter(&MapSet.member?(g.ids, &1["id"])) |> Enum.frequencies_by(& &1["type"])
        what = kinds |> Enum.sort() |> Enum.map_join(", ", fn {type, n} -> "#{n} #{type}" end)
        where = if g.raid, do: "raid", else: "fight"

        then =
          case call do
            :go -> "go in"
            :gather -> "gather at #{fmt(g.gather)}"
            :away -> "stay out of it" <> if(g.fallback, do: " (by our tower at #{fmt(g.fallback)})", else: "")
          end

        {:fight,
         "#{where} at #{fmt(Roles.nearest_in(g, g.gather))}: #{what} against #{g.size} of ours, " <>
           "estimate #{signed(g.all)} all, #{signed(g.ready)} ready: #{then}"}
      end

    {now, notes}
  end

  defp signed(x) when x >= 0, do: "+#{Float.round(x * 1.0, 2)}"
  defp signed(x), do: "#{Float.round(x * 1.0, 2)}"

  # A line for the decision log when home starts or stops falling back.
  defp fall_back_note(v, _wave, true, false) do
    exposed = Roles.exposed_raiders(v)

    [{:fall_back,
      "#{length(exposed)} raiders out of our towers' reach that home would lose to, gathered or not: " <>
        "workers and defenders fall back to the towers"}]
  end

  defp fall_back_note(_v, _wave, false, true), do: [{:fall_back, "holding again: home can meet the raiders"}]
  defp fall_back_note(_v, _wave, _now, _before), do: []

  # The raid on us: when it was last here, and how many of its fighters we have killed at home
  # (a base, an outpost or our workers) going by where we last saw them. Over once it has been gone
  # `@counter_window` ticks.
  defp raid(memory, v) do
    killed = MapSet.new(for e <- v.events, e["kind"] == "UnitKilled", do: e["entityId"])

    kills =
      Enum.count(memory.enemies, fn {id, e} ->
        MapSet.member?(killed, id) and Roles.at_home?(v, View.pos(e))
      end)

    raid = memory.raid

    cond do
      Roles.raiders(v) != [] -> %{at: v.tick, kills: kills + ((raid && raid.kills) || 0)}
      raid && v.tick - raid.at <= @counter_window -> %{raid | kills: raid.kills + kills}
      true -> nil
    end
  end

  # The look at the target before a wave leaves. Settles the one going on (a scout got there, or
  # we give up on it), and sends a new one once `@look_at` attackers wait and we haven't looked at
  # that player lately. Not while a wave is out: then a scout works in front of it.
  # Returns the look and what to log.
  defp look(memory, v, rally, owner, target, stand_in) do
    {look, why, counted} = settle_look(memory.look, v, memory, stand_in)

    lookers? = View.units_of(v, "Scout") != [] or stand_in != nil

    want? =
      cond do
        owner == nil or target == nil or v.cc == nil -> false
        looking?(look, owner) -> false
        fresh?(look, owner, v) and not stale_by_raid?(look, memory, v) -> false
        # Nobody to send: asked again once there is (the Barracks train scouts).
        not lookers? -> false
        # With a wave out, a scout works in front of it instead (see `Swarm.UnitBrain`).
        memory.wave != nil -> false
        true -> length(elem(launch_group(v, memory, rally, false), 1)) >= @look_at
      end

    if want? do
      who = if stand_in, do: "worker #{stand_in["id"]} (no scout, no ore left to mine)", else: "scout"
      lookers = length(View.units_of(v, "Scout") ++ List.wrap(stand_in))

      {%{owner: owner, pos: target, at: v.tick, done: nil, lookers: lookers},
       why ++ [{:scout_sent, "#{who} looking at player #{owner}, through to #{fmt(target)}"}], counted}
    else
      {look, why, counted}
    end
  end

  # A big raid beaten at home since the last look (`@look_after_kills` of its fighters killed here,
  # none left in sight, the look done before it was last here): that look's count is of an army
  # that has since died, and a new one goes now, not when the old one is `@look_fresh` ticks old.
  # With 43 Soldiers to their 5 after a raid of 74, the count still said 75: the counterattack
  # waited 41 ticks for the next look and met 35.
  defp stale_by_raid?(look, %{raid: %{at: at, kills: kills}}, v),
    do: kills >= @look_after_kills and Roles.raiders(v) == [] and look.done != nil and look.done <= at

  defp stale_by_raid?(_look, _memory, _v), do: false

  # Returns {the look, what to log, {player, the strength counted there} or nil}.
  defp settle_look(%{done: nil} = look, v, memory, stand_in) do
    lookers = View.units_of(v, "Scout") ++ List.wrap(stand_in)
    # There, or (a Scout, which sees 8 tiles) with the spot well inside its sight from where it is.
    {lx, ly} = look.pos

    there? =
      Enum.any?(lookers, fn u ->
        View.dist(View.pos(u), look.pos) <= @look_sight or (u["type"] == "Scout" and (u["x"] - lx) ** 2 + (u["y"] - ly) ** 2 <= 36)
      end)

    # A worker walks a tile a tick where a Scout runs two: it gets twice as long.
    timeout = if stand_in, do: 2 * @look_timeout, else: @look_timeout

    # Their fighters as we know them, and those of them seen since the scout left.
    in_sight = for u <- v.enemy_units, u["owner"] == look.owner, u["type"] not in ["Worker", "Scout"], do: Map.put(u, "seen", v.tick)
    known = Enum.uniq_by(in_sight ++ Enum.filter(Map.values(memory.enemies), &(&1["owner"] == look.owner)), & &1["id"])
    on_the_way = Enum.filter(known, &(Map.get(&1, "seen", v.tick) >= look.at))
    lost? = length(lookers) < Map.get(look, :lookers, 0)

    cond do
      there? ->
        counted = Roles.strength(known)
        why = "scouted player #{look.owner}: their base in sight, #{length(known)} fighters known, strength #{round(counted)}"
        {%{look | done: v.tick}, [{:scouted, why}], {:at_least, look.owner, counted}}

      # It died on the way in, or never got there, but saw their fighters: their army is there.
      (lost? or lookers == [] or v.tick - look.at >= timeout) and on_the_way != [] ->
        counted = max(Roles.strength(on_the_way), army_by_score(v, look.owner))

        why =
          "scouted player #{look.owner}: the scout didn't get to their base, #{length(on_the_way)} of their fighters seen on the way: " <>
            "strength #{round(counted)} by what it saw and their score"

        {%{look | done: v.tick}, [{:scouted, why}], {:at_least, look.owner, counted}}

      lost? or lookers == [] or v.tick - look.at >= timeout ->
        why = "no look at player #{look.owner} (no scout got to their base in #{v.tick - look.at} ticks): no wave leaves on that"
        {look |> Map.put(:done, v.tick) |> Map.put(:failed, true), [{:scouted, why}], nil}

      true ->
        {look, [], nil}
    end
  end

  defp settle_look(look, _v, _memory, _stand_in), do: {look, [], nil}

  # A player's army going by the scoreboard, as a strength: the ore value of everything they have
  # alive (the server reports it), less their finished buildings we know of and as many workers as
  # we have ourselves (we can't see theirs), at a Soldier's strength for its price. Their buildings
  # count for what ours are worth when we know of fewer.
  defp army_by_score(v, owner) do
    alive = Map.get(v.enemy_survival, owner, 0)

    buildings =
      (v.enemy_buildings ++ v.remembered)
      |> Enum.filter(&(&1["owner"] == owner and &1["completed"] != false))
      |> Enum.uniq_by(& &1["id"])
      |> Enum.sum_by(&Map.get(@costs, &1["type"], 0))

    # Their buildings we haven't seen: taken to be worth what ours are, at least. Counted as army,
    # three Command Centers of theirs we never saw were twelve Soldiers we trained to match, and
    # no base of ours went up all game.
    own = v.my_buildings |> Enum.filter(&(&1["completed"] != false)) |> Enum.sum_by(&Map.get(@costs, &1["type"], 0))
    buildings = max(buildings, own)

    workers = @costs["Worker"] * length(View.units_of(v, "Worker"))
    max(alive - buildings - workers, 0) * Roles.strength([%{"type" => "Soldier"}]) / @costs["Soldier"]
  end

  # The ore value of everything player `owner` has alive (the scoreboard) less their finished
  # buildings we know of: their army, their workers and the buildings we haven't seen, together.
  # Nil for a player the scoreboard has nothing for.
  defp unknown_alive(v, owner) do
    case Map.fetch(v.enemy_survival, owner) do
      # (A score of nothing alive is no score: a player still in has a Command Center.)
      {:ok, alive} when alive > 0 ->
        known =
          (v.enemy_buildings ++ v.remembered)
          |> Enum.filter(&(&1["owner"] == owner and &1["completed"] != false))
          |> Enum.uniq_by(& &1["id"])
          |> Enum.sum_by(&Map.get(@costs, &1["type"], 0))

        max(alive - known, 0)

      _ ->
        nil
    end
  end

  # A look that counted less of a player's army than we have known lately (`army_seen/3`) brings
  # that count down: to what the look counted, but no lower than `@look_trust` of the old count.
  # The 49 that died at our towers were still "known" 150 ticks on, with scouts counting 9, then 3.
  defp lower_count(army_seen, nil, _v), do: army_seen

  # Their fighters were at the spot (`settle_look/4`): their army counts for at least what was
  # counted; and a count that was higher comes down toward it like any look's.
  defp lower_count(army_seen, {:at_least, owner, counted}, v) do
    case Map.get(army_seen, owner) do
      {most, _at} when most >= counted -> lower_count(army_seen, {owner, counted}, v)
      _ -> Map.put(army_seen, owner, {counted, v.tick})
    end
  end

  defp lower_count(army_seen, {owner, counted}, v) do
    case Map.get(army_seen, owner) do
      {most, _at} when counted < most -> Map.put(army_seen, owner, {max(counted, @look_trust * most), v.tick})
      _ -> army_seen
    end
  end

  # With no Scout alive and nothing left to mine (`nothing_to_mine/2`), the idle
  # worker with the lowest id stands in for them: it goes to look at a target before a wave
  # (`Swarm.UnitBrain`). Nil otherwise.
  defp stand_in(v) do
    if v.no_ore != false and View.units_of(v, "Scout") == [] do
      v |> View.units_of("Worker") |> Enum.filter(&(&1["activity"] in ["Idle", "Moving"])) |> Enum.min_by(& &1["id"], fn -> nil end)
    end
  end

  defp looking?(look, owner), do: look != nil and look.owner == owner and look.done == nil
  # A look that came to nothing (no scout got there) is no look: a wave of 19 left on a count 115
  # ticks old after one, into 52 Soldiers, and led them home.
  defp fresh?(look, owner, v),
    do: look != nil and look.owner == owner and look.done != nil and not Map.get(look, :failed, false) and v.tick - look.done <= @look_fresh

  # `n` tiles from `from` toward `to` (or `to` itself, if it is closer).
  defp toward({fx, fy} = from, {tx, ty} = to, n) do
    d = View.dist(from, to)
    if d <= n, do: to, else: {fx + div((tx - fx) * n, d), fy + div((ty - fy) * n, d)}
  end

  defp fmt({x, y}), do: "(#{x},#{y})"

  # The most we have known of each player's army in the last `@army_memory` ticks: what we
  # remember of it now if that is more (or the old count is too old), else the old count less what
  # we have killed of it since (so beating a raid still opens the counterattack).
  defp army_seen(memory, v, before) do
    killed = MapSet.new(for e <- v.events, e["kind"] == "UnitKilled", do: e["entityId"])
    dead = before |> Map.values() |> Enum.filter(&MapSet.member?(killed, &1["id"])) |> Enum.group_by(& &1["owner"])
    now = memory.enemies |> Map.values() |> Enum.group_by(& &1["owner"])

    for owner <- Enum.uniq(Map.keys(now) ++ Map.keys(memory.army_seen)), owner != nil, into: %{} do
      known = Roles.strength(Map.get(now, owner, []))

      case Map.get(memory.army_seen, owner) do
        {most, at} when v.tick - at <= @army_memory ->
          most = max(most - Roles.strength(Map.get(dead, owner, [])), 0)
          if known >= most, do: {owner, {known, v.tick}}, else: {owner, {most, at}}

        _ ->
          {owner, {known, v.tick}}
      end
    end
  end

  # The strongest army we have known lately against all our fighters (`@together_until`).
  defp together?(memory, v) do
    theirs = memory.army_seen |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 0 end)
    ours = Roles.strength(Roles.fighters(v))

    cond do
      theirs > ours -> true
      theirs < @together_until * ours -> false
      true -> memory.together
    end
  end

  # Enemy fighters as last seen. Ones we killed, haven't seen in a while, or should see where we
  # last saw them and don't (they died out of our sight, or moved on) are dropped.
  defp remember_enemies(enemies, %View{} = v) do
    killed = for e <- v.events, e["kind"] == "UnitKilled", do: e["entityId"]

    seen =
      for u <- v.enemy_units, u["type"] != "Worker", into: %{} do
        {u["id"], u |> Map.take(["id", "owner", "type", "hp", "x", "y", "effects"]) |> Map.put("seen", v.tick)}
      end

    eyes =
      for(u <- v.my_units, do: {View.pos(u), Map.get(@vision, u["type"], @default_vision) - 1}) ++
        for b <- v.my_buildings, b["completed"], do: {View.pos(b), Map.get(@vision, b["type"], @default_vision) - 1}

    # Sight is a circle (straight-line distance), not a square: a scout six tiles off diagonally
    # sees nothing of what stands there, and they are not gone for that.
    in_sight? = fn e ->
      {ex, ey} = View.pos(e)
      Enum.any?(eyes, fn {{x, y}, r} -> (x - ex) ** 2 + (y - ey) ** 2 <= r * r end)
    end

    enemies
    |> Map.reject(fn {id, e} -> not Map.has_key?(seen, id) and in_sight?.(e) end)
    |> Map.merge(seen)
    |> Map.drop(killed)
    |> Map.reject(fn {_id, e} -> v.tick - e["seen"] > @forget_after end)
  end

  defp wave(v, memory, rally, calm?, owner, target) do
    cond do
      all_in?(v) -> Tuple.insert_at(all_in(v, memory, owner), 3, nil)
      memory.wave && Map.get(memory.wave, :kind) == :strike -> keep_strike(v, memory)
      memory.wave && Map.get(memory.wave, :kind) == :sortie -> keep_sortie(v, memory)
      memory.wave && Map.get(memory.wave, :hunt, false) -> keep_hunt(v, memory, rally)
      memory.wave -> keep_wave(v, memory, rally, Map.get(memory.wave, :goal) || target)
      memory.regroup -> {nil, memory.next_wave, [], "regrouping at the backup Command Center"}
      spot = siege_spot(v, memory) -> sortie(v, memory, spot)
      strike = strike(v, memory) -> strike
      true -> launch(v, memory, rally, calm?, owner, target)
    end
  end

  # A finished enemy tower at our door (`Swarm.Roles.towers_near_home/1`): one sent at a time, our
  # fighters only feed it, so we hit it with everyone at home at once, once that is at least
  # `@strike_min` fighters strong enough for the tower and the strongest player's units by it. It
  # comes before any wave; until it can go, nobody walks into the tower's reach
  # (`Swarm.Roles.covered?/2`).
  defp strike(v, memory) do
    raided = Roles.raiders(v) != []

    case Roles.towers_near_home(v) do
      [] ->
        nil

      [tower | _] when memory.strike_back_at != nil and v.tick - memory.strike_back_at < @strike_rest ->
        hold = "strike at player #{tower["owner"]}'s tower at #{fmt(View.pos(tower))}: back from one, #{@strike_rest - (v.tick - memory.strike_back_at)} more ticks"
        {nil, memory.next_wave, [], hold}

      [tower | _] when raided ->
        hold = "strike at player #{tower["owner"]}'s tower at #{fmt(View.pos(tower))}: not while home is being raided"
        {nil, memory.next_wave, [], hold}

      [tower | _] ->
        pos = View.pos(tower)
        roles = Roles.home_roles(v, nil)
        # The attackers: the guards stay home, so the base is never left empty.
        group = for u <- Roles.home(v, nil), roles[u["id"]] == :attacker, at_home?(v, u), do: u
        guards = Enum.filter(v.enemy_units, &(&1["type"] != "Worker" and View.dist(View.pos(&1), pos) <= @wave_sight))
        {_, theirs} = strongest_player(guards) || {nil, 0}
        # Every tower of theirs that reaches it (they cover each other), not just this one.
        towers = Enum.filter(Roles.enemy_towers(v), &(View.dist(View.pos(&1), pos) <= Roles.range(&1) + 2))
        need = Roles.strength(Enum.uniq_by([tower | towers], & &1["id"])) + @margin * theirs
        ours = Roles.strength(group)
        at = "player #{tower["owner"]}'s tower at #{fmt(pos)}"

        if length(group) >= @strike_min and ours >= need do
          wave = %{
            id: 0,
            kind: :strike,
            members: group |> Enum.map(& &1["id"]) |> Enum.sort(),
            owner: tower["owner"],
            tower: tower["id"],
            tower_pos: pos,
            released: true,
            staging: nil,
            at: v.tick
          }

          why = "strike at #{at}: #{length(group)} attackers, strength #{round(ours)} vs #{round(need)} for it"
          {wave, memory.next_wave, [{:wave_launched, why}], nil}
        else
          hold = "strike at #{at}: #{length(group)} attackers at home, want #{@strike_min} and strength #{round(need)} (have #{round(ours)})"
          {nil, memory.next_wave, [], hold}
        end
    end
  end

  # Siege at our door. A building of ours losing HP with nothing we can see able to reach it is
  # being shelled from out of sight (a Trebuchet outranges a tower, and a tower can't see its own
  # corners): up to `@checkers` home fighters go to look, one each to the four sides of it,
  # `@check_radius` out, as shells can come from anywhere. Over once we see Trebuchets (a sortie
  # takes over), a checker dies (whatever killed it we still can't see: nobody goes in after it, it
  # was an archer pack as often as siege), or after `@check_ticks`. Returns {check, what to log}.
  defp siege_watch(memory, v) do
    check = memory.check
    resting? = memory.check_rest != nil and v.tick < memory.check_rest
    alive = MapSet.new(v.my_units, & &1["id"])
    hit = for b <- v.my_buildings, prev = Map.get(memory.hp, b["id"]), b["hp"] != nil and prev != nil and b["hp"] < prev, do: b

    unseen =
      Enum.reject(hit, fn b ->
        Enum.any?(v.enemy_units, &(&1["type"] != "Worker" and View.dist(View.pos(&1), View.pos(b)) <= Roles.range(&1)))
      end)

    lost = check && Enum.find(check.checkers, fn {id, _spot} -> not MapSet.member?(alive, id) end)

    cond do
      Roles.siege_threats(v) != [] ->
        {nil, []}

      check && check.found ->
        {check, []}

      lost ->
        {_id, spot} = lost
        {nil, [{:siege_check, "a checker died by #{fmt(spot)}: a scout goes to look, no more checkers for #{@check_rest} ticks"}], spot}

      check && v.tick - check.at > @check_ticks ->
        {nil, [{:siege_check, "nothing found around #{fmt(check.pos)}"}]}

      check ->
        {check, []}

      unseen != [] and v.cc != nil and not resting? ->
        new_check(v, hd(unseen))

      true ->
        {nil, []}
    end
    |> case do
      {check, notes} -> {check, notes, nil}
      found -> found
    end
  end

  # Where a checker died, the scout closest to it goes to look (`strategy.peek`): it sees 8 tiles
  # and steps back once anything can reach it, so it comes back with what is there, and we
  # remember it. The rest of the brain then answers with real numbers (a sortie for Trebuchets,
  # holding and recalls for an army). Over once a scout gets within `@look_sight` of it, or after
  # `@peek_ticks`. Returns {the look going on, %{pos, at} or nil; notes for the decision log}.
  defp peek(memory, v, nil) do
    case memory.peek do
      nil ->
        {nil, []}

      %{pos: pos, at: at} = peek ->
        cond do
          Enum.any?(View.units_of(v, "Scout"), &(View.dist(View.pos(&1), pos) <= @look_sight)) ->
            {nil, [{:siege_check, "scout looked by #{fmt(pos)}: #{map_size(memory.enemies)} enemy fighters known"}]}

          v.tick - at > @peek_ticks ->
            {nil, []}

          true ->
            {peek, []}
        end
    end
  end

  defp peek(_memory, v, spot), do: {%{pos: spot, at: v.tick}, []}

  defp new_check(v, building) do
    {bx, by} = pos = View.pos(building)
    r = @check_radius
    spots = for {dx, dy} <- [{0, -r}, {r, 0}, {0, r}, {-r, 0}], do: {clamp(bx + dx, v.map_width), clamp(by + dy, v.map_height)}
    roles = Roles.home_roles(v, nil)

    free =
      for u <- Roles.home(v, nil), roles[u["id"]] in [:attacker, :guard] do
        {if(roles[u["id"]] == :attacker, do: 0, else: 1), View.dist(View.pos(u), pos), u}
      end
      |> Enum.sort_by(fn {kind, d, u} -> {kind, d, u["id"]} end)
      |> Enum.map(&elem(&1, 2))
      |> Enum.take(@checkers)

    {checkers, _} =
      Enum.reduce(spots, {%{}, free}, fn spot, {acc, left} ->
        case left do
          [] ->
            {acc, left}

          _ ->
            u = Enum.min_by(left, &{View.dist(View.pos(&1), spot), &1["id"]})
            {Map.put(acc, u["id"], spot), List.delete(left, u)}
        end
      end)

    if checkers == %{} do
      {nil, []}
    else
      why = "#{building["type"]} at #{fmt(pos)} is being hit by something we can't see: #{map_size(checkers)} checking around it"
      {%{building: building["id"], pos: pos, at: v.tick, checkers: checkers, found: nil}, [{:siege_check, why}]}
    end
  end

  # Where a sortie goes: the enemy Trebuchet we can see in reach of our buildings nearest one of
  # them. Nil with none: we never go in after what we can't see.
  defp siege_spot(v, _memory) do
    case Roles.siege_threats(v) do
      [] ->
        nil

      spots ->
        mine = Enum.map(v.my_buildings, &View.pos/1)
        Enum.min_by(spots, fn spot -> {mine |> Enum.map(&View.dist(&1, spot)) |> Enum.min(fn -> 99 end), spot} end)
    end
  end

  # A sortie at siege by our base: everyone at home at once (no trickling into the guarding pack),
  # at `@sortie_margin` times the enemy units there (less than the 1.5 a wave wants: they are
  # knocking our buildings down meanwhile; more than even, or it is recalled the moment one more
  # shows up), and at least `@sortie_min`. Trebuchets are first on its list: they
  # can't hit anything close, and each is 350.
  defp sortie(v, memory, spot) do
    roles = Roles.home_roles(v, nil)
    # Only those at home: a recalled wave walking back isn't sent straight into another fight.
    group = for u <- Roles.home(v, nil), roles[u["id"]] in [:guard, :attacker], at_home?(v, u), do: u
    theirs = v.enemy_units |> Enum.filter(&(&1["type"] != "Worker" and View.dist(View.pos(&1), spot) <= @wave_sight)) |> Roles.strength()
    ours = Roles.strength(group)

    if length(group) >= @sortie_min and ours >= @sortie_margin * theirs do
      wave = %{
        id: 0,
        kind: :sortie,
        members: group |> Enum.map(& &1["id"]) |> Enum.sort(),
        owner: nil,
        spot: spot,
        released: true,
        staging: nil,
        at: v.tick
      }

      why = "sortie at the siege by #{fmt(spot)}: #{length(group)} fighters, strength #{round(ours)} vs #{round(theirs)} there"
      {wave, memory.next_wave, [{:wave_launched, why}], nil}
    else
      hold = "sortie at the siege by #{fmt(spot)}: #{length(group)} fighters at home, strength #{round(ours)} vs #{round(theirs)} there"
      {nil, memory.next_wave, [], hold}
    end
  end

  # A sortie follows the siege (the nearest Trebuchet still in reach of our buildings) and comes
  # home once none is left and we have been there, or too few are left, it is outmatched, or after
  # `@sortie_ticks`.
  defp keep_sortie(v, %{wave: wave} = memory) do
    alive = Enum.filter(v.my_units, &(&1["id"] in wave.members))
    spot = siege_spot(v, %{memory | check: nil}) || wave.spot
    there? = Enum.any?(alive, &(View.dist(View.pos(&1), spot) <= 3))
    at = "the siege by #{fmt(wave.spot)}"

    cond do
      length(alive) < @recall_below ->
        {nil, memory.next_wave, [{:wave_recalled, "sortie at #{at}: only #{length(alive)} left"}], nil}

      losses = bleeding(wave, alive) ->
        {nil, memory.next_wave, [{:wave_recalled, "sortie at #{at}: #{losses}"}], nil}

      Roles.siege_threats(v) == [] and there? ->
        {nil, memory.next_wave, [{:wave_recalled, "sortie: #{at} is cleared"}], nil}

      facing = outmatched(v, alive, spot, true) ->
        {player, theirs} = facing
        why = "sortie at #{at}: outmatched by player #{player}, #{round(Roles.strength(alive))} vs #{round(theirs)}"
        {nil, memory.next_wave, [{:wave_recalled, why}], nil}

      v.tick - wave.at > @sortie_ticks ->
        {nil, memory.next_wave, [{:wave_recalled, "sortie at #{at}: given up after #{@sortie_ticks} ticks"}], nil}

      true ->
        {%{wave | members: Enum.map(alive, & &1["id"]), spot: spot} |> peaked(alive), memory.next_wave, [], nil}
    end
  end

  # A strike stays on its tower until the tower is down (we are by its tile and it is gone), too
  # few are left, the strongest player there outmatches it, or it has taken `@strike_ticks`.
  defp keep_strike(v, %{wave: wave} = memory) do
    alive = Enum.filter(v.my_units, &(&1["id"] in wave.members))
    at = "player #{wave.owner}'s tower at #{fmt(wave.tower_pos)}"

    gone? =
      not Enum.any?(v.enemy_buildings, &(&1["id"] == wave.tower)) and
        Enum.any?(v.my_units, &(View.dist(View.pos(&1), wave.tower_pos) <= 4))

    cond do
      gone? ->
        {nil, memory.next_wave, [{:wave_recalled, "strike: #{at} is down"}], nil}

      finishing?(v, alive) ->
        {%{wave | members: Enum.map(alive, & &1["id"])} |> peaked(alive), memory.next_wave, [], nil}

      length(alive) < @recall_below ->
        {nil, memory.next_wave, [{:wave_recalled, "strike at #{at}: only #{length(alive)} left"}], nil}

      losses = bleeding(wave, alive) ->
        {nil, memory.next_wave, [{:wave_recalled, "strike at #{at}: #{losses}"}], nil}

      raid = Roles.recall(v, wave) ->
        {theirs, ours} = raid
        why = "strike at #{at}: home under attack, strength #{round(theirs)} vs #{round(ours)} at home"
        {nil, memory.next_wave, [{:wave_recalled, why}], nil}

      facing = outmatched(v, alive, wave.tower_pos, true) ->
        {player, theirs} = facing
        why = "strike at #{at}: outmatched by player #{player}, #{round(Roles.strength(alive))} vs #{round(theirs)}"
        {nil, memory.next_wave, [{:wave_recalled, why}], nil}

      v.tick - wave.at > @strike_ticks ->
        {nil, memory.next_wave, [{:wave_recalled, "strike at #{at}: given up after #{@strike_ticks} ticks"}], nil}

      true ->
        {%{wave | members: Enum.map(alive, & &1["id"])} |> peaked(alive), memory.next_wave, [], nil}
    end
  end

  # The player the wave went after has been eliminated.
  defp wave_owner_out?(v, %{owner: owner}) when owner != nil, do: not Map.has_key?(v.enemy_survival, owner)
  defp wave_owner_out?(_v, _wave), do: false

  # Some of `alive` are by a nearly dead enemy Command Center (`Roles.finishable_ccs/1`): the wave
  # stays out until it falls, whatever else would call it off. Two more ticks there eliminate a
  # player; walking away left one at 195 HP.
  defp finishing?(v, alive) do
    Enum.any?(Roles.finishable_ccs(v), fn cc -> Enum.any?(alive, &(View.dist(View.pos(&1), View.pos(cc)) <= 6)) end)
  end

  # Called off sooner: a wave, strike or sortie that has lost `@call_off` of the most it ever had
  # (counting reinforcements) is losing, whatever is left. Waiting until only `@recall_below` are
  # left fed it to them a few at a time. The reason, or nil.
  defp bleeding(wave, alive) do
    peak = Map.get(wave, :peak, 0)
    now = Roles.strength(alive)
    if peak > 0 and now < (1 - @call_off) * peak, do: "lost #{round(100 * (1 - now / peak))}% of its strength (#{round(now)} of #{round(peak)})"
  end

  # The wave with the most it has had so far.
  defp peaked(wave, alive), do: Map.put(wave, :peak, max(Map.get(wave, :peak, 0), Roles.strength(alive)))

  # Near the end and behind on score: every fighter goes, including new ones.
  defp all_in?(v), do: v.tick >= v.max_ticks - @all_in_ticks and v.my_score < v.enemy_score

  # Each returns {wave, next wave id, why}.
  defp all_in(v, memory, owner) do
    # Trebuchets too: they shell what the fighters can't reach.
    members = (Roles.fighters(v) ++ View.units_of(v, "Trebuchet")) |> Enum.map(& &1["id"]) |> Enum.sort()

    case memory.wave do
      %{all_in: true} = wave ->
        {%{wave | members: members}, memory.next_wave, []}

      _ ->
        why =
          "behind on score (#{v.my_score} vs #{v.enemy_score}) with #{v.max_ticks - v.tick} ticks left: " <>
            "all #{length(Roles.fighters(v))} fighters and #{length(View.units_of(v, "Trebuchet"))} trebuchet(s) attack"

        {%{id: memory.next_wave, members: members, all_in: true, owner: owner}, memory.next_wave + 1, [{:all_in, why}]}
    end
  end

  # Keep the wave that is out (minus its dead), unless home needs it, too few are left, or what
  # its front is facing is stronger than the whole wave, reinforcements on their way included (they
  # go out and come back together). A recalled wave is just fighters at home again: they walk back
  # and defend, and fight on the way only what attacks them. Attackers at the rally point follow it
  # in batches of `@batch`.
  defp keep_wave(v, %{wave: wave} = memory, rally, target) do
    alive = Enum.filter(v.my_units, &(&1["id"] in wave.members))

    cond do
      finishing?(v, alive) ->
        {%{wave | members: Enum.map(alive, & &1["id"])} |> peaked(alive), memory.next_wave, [], nil}

      # Safe mode (`spare/3`): it goes for their last Command Center, whatever happens at home or
      # to it on the way. Their army can't take back what the end of the match keeps.
      memory.kill != nil and alive != [] ->
        {%{wave | members: Enum.map(alive, & &1["id"])} |> peaked(alive), memory.next_wave, [], nil}

      # Its player is out: it comes home, not on into the next one (it walked into the middle and
      # bled last time). The next wave waits for it, and for a look at its target (`launch/6`).
      wave_owner_out?(v, wave) ->
        {nil, memory.next_wave, [{:wave_recalled, "wave #{wave.id}: player #{wave.owner} is out, coming home"}], nil}

      home = Roles.recall(v, wave) ->
        {theirs, ours} = home
        why = "wave #{wave.id}: home under attack, strength #{round(theirs)} vs #{round(ours)} at home"
        {nil, memory.next_wave, [{:wave_recalled, why}], nil}

      coming = army_near_home(v, memory, wave) ->
        {player, theirs, ours} = coming
        why = "wave #{wave.id}: player #{player}'s army is near home, strength #{round(theirs)} vs #{round(ours)} at home"
        {nil, memory.next_wave, [{:wave_recalled, why}], nil}

      length(alive) < @recall_below and not party?(wave, alive) ->
        {nil, memory.next_wave, [{:wave_recalled, "wave #{wave.id}: only #{length(alive)} left"}], nil}

      losses = bleeding(wave, alive) ->
        {nil, memory.next_wave, [{:wave_recalled, "wave #{wave.id}: #{losses}"}], nil}

      facing = outmatched(v, alive, target, not party?(wave, alive)) ->
        {player, theirs} = facing
        why = "wave #{wave.id}: outmatched by player #{player}, strength #{round(Roles.strength(alive))} vs #{round(theirs)} nearby"
        {nil, memory.next_wave, [{:wave_recalled, why}], nil}

      true ->
        wave = %{wave | members: Enum.map(alive, & &1["id"])} |> peaked(alive)
        {wave, more, hold} = reinforce(v, wave, rally)
        {wave, next_wave, why} = release(v, wave, memory.next_wave, target)
        {wave, next_wave, more ++ why, hold}
    end
  end

  # A wave after a boom's open base (`open_base/4`): kept like any wave while the base it went for
  # is still open (still there as far as we know, with no more towers by it than it may have);
  # then on to the next open one, and home when there is none.
  defp keep_hunt(v, %{wave: wave} = memory, rally) do
    alive = Enum.filter(v.my_units, &(&1["id"] in wave.members))

    cond do
      open?(v, wave.owner, wave.goal) ->
        keep_wave(v, memory, rally, wave.goal)

      next = alive != [] && open_base(v, memory, wave.owner, alive) ->
        {kept, next_wave, why, hold} = keep_wave(v, %{memory | wave: %{wave | goal: next}}, rally, next)
        {kept, next_wave, [{:wave_reinforced, "wave #{wave.id}: on to their base by #{fmt(next)}"} | why], hold}

      true ->
        {nil, memory.next_wave, [{:wave_recalled, "wave #{wave.id}: no base of player #{wave.owner}'s left without towers, coming home"}], nil}
    end
  end

  # A siege party (`@siege_idle`) for as long as it still has a Trebuchet.
  defp party?(wave, alive), do: Map.get(wave, :party, false) and Enum.any?(alive, &(&1["type"] == "Trebuchet"))

  # Within `@home_watch` of the Command Center (everything is, with none).
  defp at_home?(%View{cc: nil}, _unit), do: true
  defp at_home?(v, unit), do: View.dist(View.pos(unit), View.pos(v.cc)) <= @home_watch

  # An enemy army near home that what stays home (everything not in `wave`, and our towers by it)
  # can't meet: the strongest single player's fighters we remember within `@home_watch` of the
  # Command Center, as {player, their strength, ours}, or nil. Raids are only counted once they are
  # in a base (`Roles.recall/2`); this sees them coming, so a wave doesn't leave as they arrive, and
  # one out comes back before home is overrun.
  defp army_near_home(%View{cc: nil}, _memory, _wave), do: nil

  defp army_near_home(v, memory, wave) do
    home = View.pos(v.cc)

    near =
      for {_id, e} <- memory.enemies,
          e["type"] not in ["Worker", "Scout"],
          View.dist(View.pos(e), home) <= @home_watch,
          do: e

    with {player, theirs} <- strongest_player(near),
         ours = Roles.all_home_strength(v, wave, Enum.filter(near, &(&1["owner"] == player))),
         true <- theirs > ours do
      {player, theirs, ours}
    else
      _ -> nil
    end
  end

  # `@batch` attackers at the rally point go after the wave, if home can still hold without them.
  defp reinforce(v, wave, rally) do
    in_wave = Enum.count(Roles.fighters(v), &(&1["id"] in wave.members))
    room = max(wave_cap(v) - in_wave, 0)
    # Only as many as fit under the cap, the closest to the rally point first.
    staged =
      staged(v, wave, rally, @staged_radius)
      |> Enum.sort_by(&{View.dist(View.pos(&1), rally), &1["id"]})
      |> Enum.take(room)

    ids = Enum.map(staged, & &1["id"])

    cond do
      room < @batch ->
        {wave, [], "reinforcements: the wave is at its cap (#{in_wave} of #{wave_cap(v)}), the rest stay home"}

      length(staged) < @batch ->
        {wave, [], "reinforcements: #{length(staged)} of #{@batch} at the rally point"}

      Roles.recall(v, %{wave | members: wave.members ++ ids}) != nil ->
        {wave, [], "reinforcements: home couldn't hold the raid without the #{length(staged)} at the rally point"}

      true ->
        why = "wave #{wave.id}: #{length(staged)} more follow it (#{length(wave.members) + length(staged)} in all)"
        {%{wave | members: Enum.sort(wave.members ++ ids)}, [{:wave_reinforced, why}], nil}
    end
  end

  # The most fighters a wave may have: `@wave_floor`, or two thirds of all our fighters once that
  # is more. Until we have `@wave_floor` plus the guards, a wave may take everyone but them; past
  # that, a third of the army stays home. (The end-of-match all-in takes everyone regardless.)
  defp wave_cap(v), do: max(@wave_floor, div(2 * length(Roles.fighters(v)), 3))

  # Attackers (not guards or escorts) within `radius` of the rally point.
  defp staged(v, wave, rally, radius) do
    roles = Roles.home_roles(v, wave)

    for u <- Roles.home(v, wave),
        roles[u["id"]] == :attacker,
        View.dist(View.pos(u), rally) <= radius,
        do: u
  end

  # Who a new wave would take and where it leaves from, as {launch point, attackers}: no more than
  # the wave may take (`wave_cap/1`), the closest to the launch point first. Normally the
  # attackers at the rally point (within `@counter_radius` of it for a counterattack). But after a
  # defend the army is often still out where it fought, at an outpost or by our workers, and
  # walking it all home first held a 4-to-1 army back for 270 ticks while raiders kept poking at
  # the outpost. So with nothing attacking us now and too few at the rally point for a wave, the
  # biggest group out there (`field_group/2`) is the one weighed instead, from where it stands, on
  # the same launch test.
  defp launch_group(v, memory, rally, counter?) do
    at_rally = staged(v, nil, rally, if(counter?, do: @counter_radius, else: @staged_radius))
    calm_now? = Roles.threat(v) == nil and Roles.help_wanted(v) == []

    field = if calm_now? and length(at_rally) < wave_min(v, memory), do: field_group(v, rally)

    {from, group} =
      case field do
        {center, group} when length(group) > length(at_rally) -> {center, group}
        _ -> {rally, at_rally}
      end

    {from, group |> Enum.sort_by(&{View.dist(View.pos(&1), from), &1["id"]}) |> Enum.take(wave_cap(v))}
  end

  # The biggest group of attackers out in the field after a defend: those at one of our bases or
  # by our workers (`Swarm.Roles.at_home?/2`: where a defend sends them; a recalled wave walking
  # home in the open doesn't count) and more than `@counter_radius` from the rally point (closer
  # than that they are on their way in). The group is everyone within `@field_radius` of the
  # attacker with the most others that close. {its center, the group}, or nil with none out.
  defp field_group(v, rally) do
    roles = Roles.home_roles(v, nil)

    out =
      for u <- Roles.home(v, nil),
          roles[u["id"]] == :attacker,
          pos = View.pos(u),
          View.dist(pos, rally) > @counter_radius,
          Roles.at_home?(v, pos),
          do: u

    near = fn center -> Enum.filter(out, &(View.dist(View.pos(&1), center) <= @field_radius)) end

    case out do
      [] ->
        nil

      _ ->
        center = out |> Enum.max_by(&{length(near.(View.pos(&1))), -&1["id"]}) |> View.pos()
        {center, near.(center)}
    end
  end

  # A wave holding at its staging point goes in once its Trebuchets are there (or gone), or after
  # `@siege_wait` ticks in case they are stuck.
  # Then, with towers by the target (`@siege_clear`), the Trebuchets shell them from outside their
  # reach while the rest holds at the staging point (`sieging`, the tick it began): attack-moving
  # in, a Trebuchet fires at the nearest unit and the soldiers die under the towers it was built
  # for. Everyone goes in once those towers are down, the Trebuchets are gone, or no tower has
  # fallen for `@siege_idle` ticks.
  defp release(v, %{released: false} = wave, next_wave, target) do
    siege = Enum.filter(v.my_units, &(&1["type"] == "Trebuchet" and &1["id"] in wave.members))
    there? = Enum.all?(siege, &(View.dist(View.pos(&1), wave.staging) <= @staged_radius))
    towers = if target, do: Enum.count(Roles.enemy_towers(v), &(View.dist(View.pos(&1), target) <= @siege_clear)), else: 0

    case Map.get(wave, :sieging) do
      nil when siege != [] and towers > 0 and (there? or v.tick - wave.at >= @siege_wait) ->
        why = "wave #{wave.id}: #{length(siege)} trebuchet(s) in place, shelling #{towers} tower(s) by #{fmt(target)}; the rest hold"
        {Map.put(wave, :sieging, v.tick), next_wave, [{:wave_released, why}]}

      nil when there? or v.tick - wave.at >= @siege_wait ->
        why = "wave #{wave.id}: #{length(siege)} trebuchet(s) in place, going in"
        {%{wave | released: true}, next_wave, [{:wave_released, why}]}

      nil ->
        {wave, next_wave, []}

      since ->
        # {towers standing, the tick one last fell (or the shelling began)}.
        {standing, fell_at} = Map.get(wave, :siege_mark, {towers, since})
        {standing, fell_at} = if towers < standing, do: {towers, v.tick}, else: {standing, fell_at}

        done =
          cond do
            siege == [] -> "its trebuchets are gone"
            towers == 0 -> "the towers by #{fmt(target)} are down"
            v.tick - fell_at >= @siege_idle -> "no tower down in #{@siege_idle} ticks, #{towers} still up"
            true -> nil
          end

        if done,
          do: {%{wave | released: true}, next_wave, [{:wave_released, "wave #{wave.id}: #{done}, going in"}]},
          else: {Map.put(wave, :siege_mark, {standing, fell_at}), next_wave, []}
    end
  end

  defp release(_v, wave, next_wave, _target), do: {wave, next_wave, []}

  # The strongest single enemy player at the wave's front, as {player, strength}, if stronger than
  # the whole wave; else nil. Players are counted apart: two fighting each other near us don't add
  # up, and we may well come in on them.
  # The front: the members within `@wave_sight` of the one nearest the target (reinforcements
  # walking up behind are counted in the wave, not in where it is fighting).
  defp outmatched(v, alive, target, towers?) do
    case facing(v, alive, target, towers?) do
      {_player, theirs} = top when theirs > 0 -> if Roles.strength(alive) < theirs, do: top
      _ -> nil
    end
  end

  # The strongest single enemy player at the wave's front, as {player, strength}, or nil; their
  # towers there count unless `towers?` is false (a siege party's).
  defp facing(v, alive, target, towers?) do
    lead = if target, do: Enum.min_by(alive, &View.dist(View.pos(&1), target)), else: hd(alive)
    front = Enum.filter(alive, &(View.dist(View.pos(&1), View.pos(lead)) <= @wave_sight))
    n = length(front)
    center = {div(Enum.sum_by(front, & &1["x"]), n), div(Enum.sum_by(front, & &1["y"]), n)}
    near? = &(View.dist(View.pos(&1), center) <= @wave_sight)

    (Enum.filter(v.enemy_units, &(&1["type"] != "Worker" and near?.(&1))) ++
       if(towers?, do: Enum.filter(Roles.enemy_towers(v), near?), else: []))
    |> strongest_player()
  end

  # An enemy building at our main base's door, for our attackers to kill now (its id): a site
  # within `@raze_reach` of the Command Center first, then a finished building (not a tower: a
  # strike deals with those) within `@raze_built`. Never because it is by an outpost: our outposts
  # sit by enemy bases, and that emptied the base for their Barracks. Not while home or our workers
  # are being raided, not under an enemy tower, and only where home can take what is there
  # (`Roles.can_take?/3`). The guards stay home (`Swarm.UnitBrain`).
  defp raze(v) do
    home = View.pos(v.cc)
    from_home = &View.dist(View.pos(&1), home)

    targets =
      v.enemy_buildings
      |> Enum.filter(fn b ->
        if b["completed"] == false,
          do: from_home.(b) <= @raze_reach,
          else: b["type"] != "GuardTower" and from_home.(b) <= @raze_built
      end)
      |> Enum.sort_by(&{if(&1["completed"] == false, do: 0, else: 1), from_home.(&1), &1["id"]})

    if Roles.raiders(v) == [] do
      targets
      |> Enum.find(&(not Roles.covered?(v, View.pos(&1)) and Roles.can_take?(v, nil, View.pos(&1))))
      |> case do
        nil -> nil
        b -> b["id"]
      end
    end
  end

  # The moment for the serum (once a match): home is being overrun and the help we have won't do.
  # Home is everything at home, wherever it stands (`Roles.all_home_strength/3`), not only what is
  # by the raid: a raid is only overrunning us if all of home can't meet it.
  # A raid of at least `@serum_raid` hits a base, an outpost or our workers, we have
  # `@serum_soldiers` soldiers or more, and:
  #   - with a wave out that can be back within `@help_eta` ticks (soldiers walk a tile a tick):
  #     the raid is stronger than home and the wave together (recalling the wave alone won't do);
  #   - otherwise (no wave, or too far to make it): the raid is at least `@serum_margin` times what
  #     can meet it at home: an even fight or worse. (It was 1.25: taken only once we were clearly
  #     losing, by when too few Soldiers were left for it to turn anything; 23 Soldiers stood
  #     through the start of an even fight with it unused, and 5 were left when it qualified.)
  #     The serum doubles soldiers' speed too, so a far wave gets home twice as fast.
  # `wave` is the wave out before this tick's recall (a recalled wave is still the help coming).
  # Never for the wave's own fights: it should win those anyway.
  defp serum_moment?(v, wave) do
    raiders = Roles.raiders(v)
    raid = Roles.strength(raiders)
    home = Roles.all_home_strength(v, wave, raiders)
    out = if wave, do: Enum.filter(v.my_units, &(&1["id"] in wave.members)), else: []

    near? =
      out != [] and
        Enum.min(for(u <- out, r <- raiders, do: View.dist(View.pos(u), View.pos(r))), fn -> 99 end) <= @help_eta

    overrun? = if near?, do: raid > home + Roles.strength(out), else: raid >= @serum_margin * home

    # And it has to turn the fight: the fight's own estimate, worked out again with our Soldiers
    # on the serum (`View.serum_on`), has all of ours coming out ahead of some raid they are in.
    # ("Our Soldiers counted twice at least match the raid" said yes to 40 Soldiers against 71:
    # the estimate with it was -0.3, nobody went in, and it got 12 kills.)
    raider_ids = MapSet.new(raiders, & &1["id"])
    on = %{v | serum_on: true, shared: v.shared && Map.delete(v.shared, :groups)}

    # Some raid worth it, that is (`@serum_raid`): two Soldiers we would beat anyway turned "it"
    # while 50 more came into sight, and the serum was gone when they got there.
    turns_it? =
      Enum.any?(Roles.groups(on, wave).groups, fn {_id, g} ->
        g.size > 0 and g.worth >= @serum_raid and g.all >= 0 and Enum.any?(g.ids, &MapSet.member?(raider_ids, &1))
      end)

    # Or the fight is joined whatever the odds: a raid worth it is inside our base
    # (`Roles.inside?/2`), where everyone fights it (`Swarm.UnitBrain`), with `@serum_soldiers`
    # of ours or more in it. That is the fight the serum is for; kept for a fight it would turn
    # by the estimate, it was taken on fights we were staying out of, or not at all.
    joined? =
      Enum.any?(Roles.groups(v, wave).groups, fn {_id, g} ->
        g.size >= @serum_soldiers and g.worth >= @serum_raid and Roles.inside?(v, g) and Enum.any?(g.ids, &MapSet.member?(raider_ids, &1))
      end)

    # Or they have taken theirs: raiders on the serum (the server marks each, `Roles.serum?/1`,
    # and they count double in `raid` above) are answered with ours, whatever the odds.
    answer? = Enum.any?(raiders, &Roles.serum?/1)

    # Wherever the fight is, raid or not: a group worth it with fighters on the serum and
    # `@serum_soldiers` of ours or more in its fight. 64 of ours met 47 a few tiles off a depot of
    # ours, in no raid by the book; theirs went on, ours 12 ticks later, with 38 Soldiers dead.
    on_serum = for e <- v.enemy_units, Roles.serum?(e), into: MapSet.new(), do: e["id"]

    met? =
      MapSet.size(on_serum) > 0 and
        Enum.any?(Roles.groups(v, wave).groups, fn {_id, g} ->
          g.size >= @serum_soldiers and g.worth >= @serum_raid and Enum.any?(g.ids, &MapSet.member?(on_serum, &1)) and
            in_contact?(v, g, on_serum)
        end)

    length(View.units_of(v, "Soldier")) >= @serum_soldiers and
      (met? or (raiders != [] and ((raid >= @serum_raid and overrun? and turns_it?) or joined? or answer?)))
  end

  # `@serum_soldiers` of our Soldiers or more within `@serum_contact` of a fighter of group `g` on
  # the serum: the fight is on, not just in sight. Taken on sight, ours ran for 30 ticks before a blow.
  defp in_contact?(v, g, on_serum) do
    theirs = for e <- v.enemy_units, MapSet.member?(on_serum, e["id"]), MapSet.member?(g.ids, e["id"]), do: View.pos(e)
    Enum.count(View.units_of(v, "Soldier"), fn u -> Enum.any?(theirs, &(View.dist(&1, View.pos(u)) <= @serum_contact)) end) >= @serum_soldiers
  end

  # {player, strength} of the strongest single player among these units and towers, or nil.
  defp strongest_player([]), do: nil

  defp strongest_player(units) do
    units
    |> Enum.group_by(& &1["owner"])
    |> Enum.map(fn {owner, us} -> {owner, Roles.strength(us)} end)
    |> Enum.max_by(fn {owner, strength} -> {strength, -(owner || 0)} end)
  end

  # The strongest single player's fighters we can see near the rally point or on the way to the
  # target, as {player, strength}, or nil. Their towers aren't counted: the strength test already
  # counts the target's.
  defp in_the_way(v, rally, target) do
    d = View.dist(rally, target)
    path = for k <- 0..d//4, do: toward(rally, target, k)

    v.enemy_units
    |> Enum.filter(fn u -> u["type"] != "Worker" and Enum.any?(path, &(View.dist(&1, View.pos(u)) <= @wave_sight)) end)
    |> strongest_player()
  end

  # Send the attackers waiting at the rally point once they are strong enough, if what stays home
  # can hold whatever is hitting us right now, and not just after a recall for home (`calm?`).
  # Knowing nothing about the enemy yet, wait for `@first_wave` of them. Right after we beat a
  # raid (`counter?/2`), every attacker near the rally point may go, recall or not. Otherwise the
  # fourth element says why we wait.
  defp launch(v, memory, rally, calm?, owner, target) do
    counter? = counter?(memory, v)
    # Where the wave leaves from: the rally point, or where the army stands after a defend.
    {from, staged} = launch_group(v, memory, rally, counter?)
    attackers = for {_id, :attacker} <- Roles.home_roles(v, nil), do: 1

    # Trebuchets waiting at the rally point go too, if there are enough of them.
    siege =
      for u <- View.units_of(v, "Trebuchet"),
          View.dist(View.pos(u), rally) <= @staged_radius,
          do: u

    at_rally = siege
    siege = if length(siege) >= @siege_group, do: siege, else: []

    ours = Roles.strength(staged ++ siege)
    theirs = enemy_strength(v, memory, owner)
    # With two or more opponents in, their army counts for at least what the scoreboard says
    # (`army_by_score/2`), whatever a scout saw at their base: a house bot's army is often out. A
    # look at an empty base sent 14, then 20, at "0 known"; they met 33 Soldiers' worth, were
    # caught running home, and 8 were left against two opponents at tick 318.
    theirs =
      if owner != nil and map_size(v.start_owner) >= 2,
        do: theirs - enemy_army(memory, owner) + max(enemy_army(memory, owner), army_by_score(v, owner)),
        else: theirs

    # An army counted lately (`army_seen/3`) is something known, in sight now or not.
    scouted? = memory.enemies != %{} or v.enemy_buildings != [] or v.remembered != [] or theirs > 0

    # All they have alive that we don't know to be a building is worth next to nothing
    # (`unknown_alive/2`): they have no army, whatever we counted of it last and with or without a
    # look. One sat for a hundred ticks with 3 Soldiers, 5 workers, three Command Centers and
    # seven Barracks while no wave of ours left: both scouts sent to look died at its towers
    # having seen no fighter, which was no look.
    alive = owner && unknown_alive(v, owner)
    no_army? = alive != nil and alive <= @no_army_ore
    left = if no_army?, do: alive * Roles.strength([%{"type" => "Soldier"}]) / @costs["Soldier"]
    theirs = if no_army?, do: enemy_strength(v, memory, owner) - enemy_army(memory, owner) + min(enemy_army(memory, owner), left), else: theirs

    early? = early_strike?(v, memory, owner, staged, ours, theirs)

    want =
      cond do
        early? -> @early_min
        no_army? -> min(@open_min, wave_min(v, memory))
        true -> wave_min(v, memory)
      end

    # A siege party (`@siege_idle`): too few attackers for a wave, Trebuchets at the rally point,
    # and those attackers `@margin` times their army as we know it (towers aside).
    their_army = enemy_army(memory, owner)
    gone? = Roles.strength(staged) >= @margin * their_army
    # Their army alive: a base of theirs it isn't at, if we have the escort for it.
    hunt = if at_rally != [] and not gone? and length(staged) >= @hunt_escort, do: soft_target(v, memory, owner, staged)
    party? = at_rally != [] and ((length(staged) < want and gone?) or hunt != nil)
    target = if party? and hunt, do: hunt, else: target
    siege = if party?, do: at_rally, else: siege
    ours = if party?, do: Roles.strength(staged ++ siege), else: ours

    # A neighbor that reads as a boom (`Swarm.Reads`): a base of theirs with next to no towers by
    # it (`open_base/4`) is gone for now, with `@open_min` attackers or more, before the towers go
    # up; no waiting for a full wave or our own tower square, and their towers elsewhere don't
    # count against it.
    open = if not party? and Reads.kind(Map.get(memory, :reads, %{}), owner) == :boom and length(staged) >= @open_min, do: open_base(v, memory, owner, staged)
    target = open || target

    ready? =
      cond do
        party? -> true
        open != nil -> true
        scouted? -> length(staged) >= want and ours >= @margin * theirs
        true -> length(staged) >= max(@first_wave, want)
      end

    leaving = %{members: Enum.map(staged ++ siege, & &1["id"])}
    home = Roles.recall(v, leaving)
    place = if from == rally, do: "the rally point", else: fmt(from)
    waiting = "#{length(staged)} attackers at #{place} (#{length(attackers)} in all)"

    hold =
      cond do
        not calm? and not counter? ->
          "back from a recall for home, #{@calm_ticks - (v.tick - memory.recalled_at)} more ticks"

        memory.raid && Roles.raiders(v) == [] && v.tick - memory.raid.at < @raid_gone ->
          "a raid only just out of sight, #{@raid_gone - (v.tick - memory.raid.at)} more ticks"

        memory.came_home_at && v.tick - memory.came_home_at < @calm_ticks ->
          "the last wave took its player out and is coming home, #{@calm_ticks - (v.tick - memory.came_home_at)} more ticks"

        memory.check_next and not fresh?(memory.look, owner, v) ->
          "#{waiting}, a look at player #{owner} first: the next one after taking one out"

        memory.army_recalled_at && v.tick - memory.army_recalled_at < @calm_ticks ->
          "back from a recall for an army near home, #{@calm_ticks - (v.tick - memory.army_recalled_at)} more ticks"

        not scouted? and not ready? ->
          "#{waiting}, want #{max(@first_wave, want)} while nothing is scouted"

        length(staged) < want and not party? and open == nil ->
          "#{waiting}, want #{want}"

        (towers = if(early? or party? or open != nil, do: nil, else: towers_short(v, memory))) != nil ->
          "#{waiting}, building the tower square first (#{towers} of #{@big_towers})"

        not counter? and not no_army? and looking?(memory.look, owner) ->
          "#{waiting}, scout looking at player #{owner} (#{v.tick - memory.look.at} ticks)"

        # No wave without a look at them that got there, lately (`fresh?/3`). A counterattack right
        # after a beaten raid and a siege party against no army go without.
        not counter? and not party? and not no_army? and not fresh?(memory.look, owner, v) ->
          "#{waiting}, no look at player #{owner} lately: none leaves on an old count"

        not ready? ->
          "#{waiting}, strength #{round(ours)} vs #{@margin} x #{round(theirs)} = #{round(@margin * theirs)} known of player #{owner}"

        (way = target && in_the_way(v, from, target)) && elem(way, 1) > ours ->
          {player, strength} = way
          "#{waiting}, player #{player}'s army is in the way (#{round(strength)} vs our #{round(ours)})"

        home != nil ->
          {raid, left} = home
          "home couldn't hold the raid without them (#{round(raid)} vs #{round(left)} left home)"

        coming = army_near_home(v, memory, leaving) ->
          {player, theirs, left} = coming
          "player #{player}'s army is near home (#{round(theirs)} vs #{round(left)} left home)"

        true ->
          nil
      end

    if hold == nil do
      with_siege = if siege == [], do: "", else: " and #{length(siege)} trebuchets"
      counter =
        cond do
          counter? -> "counterattack: "
          party? and hunt != nil -> "siege party at their base by #{fmt(hunt)}, none of their army we know of near it: "
          party? -> "siege party (their army is gone, #{round(their_army)} known): "
          open != nil -> "they read as a boom, and their base by #{fmt(open)} has next to no towers: "
          early? -> "early strike on a weak neighbor: "
          true -> ""
        end

      why =
        if scouted?,
          do:
            "#{counter}wave #{memory.next_wave} at player #{owner}: #{length(staged)} attackers#{with_siege}, " <>
              "strength #{round(ours)} vs #{round(theirs)} known",
          else: "#{counter}wave #{memory.next_wave} at player #{owner}: #{length(staged)} attackers#{with_siege}, nothing scouted yet"

      wave = %{
        id: memory.next_wave,
        members: (staged ++ siege) |> Enum.map(& &1["id"]) |> Enum.sort(),
        owner: owner,
        # With siege, everyone holds short of the target until it arrives.
        staging: if(siege != [], do: staging(v, target, from)),
        released: siege == [],
        at: v.tick,
        party: party?,
        # Where a hunting party goes (`soft_target/4`); nil for everyone else: the usual target.
        goal: if(party?, do: hunt, else: open),
        # After an open base of a boom (`open_base/4`): it moves on to the next, or comes home.
        hunt: open != nil
      }

      {wave, memory.next_wave + 1, [{:wave_launched, why}], nil}
    else
      {nil, memory.next_wave, [], hold}
    end
  end

  # We just beat a raid: it has been gone `@raid_gone` ticks (not just stepped out of sight for a
  # moment: archers do that, and a counterattack left into them and was called straight back), we
  # killed `@counter_kills` of its fighters at home, and it was here within `@counter_window` ticks.
  defp counter?(%{raid: %{at: at, kills: kills}}, v),
    do: Roles.raiders(v) == [] and kills >= @counter_kills and v.tick - at >= @raid_gone and v.tick - at <= @counter_window

  defp counter?(_memory, _v), do: false

  @doc """
  The army we remember of player `owner` (all opponents if nil), or the most we have known of it
  in the last #{@army_memory} ticks if that is more, plus their finished towers we know of. An enemy
  remembered without an owner counts against everyone.
  """
  def enemy_strength(%View{} = v, memory, owner \\ nil) do
    theirs? = &(owner == nil or &1["owner"] in [owner, nil])

    towers =
      (v.enemy_buildings ++ v.remembered)
      |> Enum.filter(&(&1["type"] == "GuardTower" and &1["completed"] != false and theirs?.(&1)))
      |> Enum.uniq_by(& &1["id"])

    enemy_army(memory, owner) + Roles.strength(towers)
  end

  # A drop-off of `owner`'s (Command Center or Resource Depot we know of) their army isn't at:
  # the fighters of theirs we remember within `@hunt_clear` of it are no more than the escort can
  # meet (`@margin`). The one with the fewest of them by it, then the nearest to us. Nil with none.
  defp soft_target(v, memory, owner, escort) do
    from = if v.cc, do: View.pos(v.cc), else: center(v)
    ours = Roles.strength(escort)
    fighters = memory.enemies |> Map.values() |> Enum.filter(&(&1["owner"] in [owner, nil]))
    # Only when we know where their army is: the fighters we remember are `@hunt_known` of it or
    # more. With none of them remembered, every base of theirs looked clear, and 32 Soldiers and
    # two Trebuchets left for the one their 70 stood by.
    known? = Roles.strength(fighters) >= @hunt_known * enemy_army(memory, owner)

    (v.enemy_buildings ++ v.remembered)
    |> Enum.filter(&(known? and &1["owner"] == owner and &1["type"] in ["CommandCenter", "ResourceDepot"]))
    |> Enum.uniq_by(& &1["id"])
    |> Enum.map(fn b ->
      pos = View.pos(b)
      {Roles.strength(Enum.filter(fighters, &(View.dist(View.pos(&1), pos) <= @hunt_clear))), View.dist(pos, from), pos}
    end)
    |> Enum.filter(fn {near, _d, _pos} -> ours >= @margin * near end)
    |> Enum.min(fn -> nil end)
    |> case do
      nil -> nil
      {_near, _d, pos} -> pos
    end
  end

  # A base of `owner`'s open to an attack: a Command Center or Resource Depot we know of with no
  # more than `@open_towers` finished towers of theirs within `@open_cover` of it, where those
  # towers and the fighters of theirs we remember within `@hunt_clear` are no more than `escort`
  # can meet (`@margin`). The one with the fewest towers, then the nearest to us. Nil with none.
  defp open_base(v, memory, owner, escort) do
    from = if v.cc, do: View.pos(v.cc), else: center(v)
    ours = Roles.strength(escort)
    fighters = memory.enemies |> Map.values() |> Enum.filter(&(&1["owner"] in [owner, nil] and &1["type"] != "Scout"))

    known_of(v, owner)
    |> Enum.filter(&(&1["type"] in ["CommandCenter", "ResourceDepot"]))
    |> Enum.map(fn b ->
      pos = View.pos(b)
      cover = towers_by(v, owner, pos)
      near = Enum.filter(fighters, &(View.dist(View.pos(&1), pos) <= @hunt_clear))
      {length(cover), View.dist(pos, from), pos, Roles.strength(near) + Roles.strength(cover)}
    end)
    |> Enum.filter(fn {towers, _d, _pos, theirs} -> towers <= @open_towers and ours >= @margin * theirs end)
    |> Enum.min(fn -> nil end)
    |> case do
      nil -> nil
      {_towers, _d, pos, _theirs} -> pos
    end
  end

  # Whether `owner` still has a building at `pos`, as far as we know, with no more than
  # `@open_towers` finished towers by it.
  defp open?(v, owner, pos),
    do: Enum.any?(known_of(v, owner), &(View.pos(&1) == pos)) and length(towers_by(v, owner, pos)) <= @open_towers

  defp known_of(v, owner),
    do: (v.enemy_buildings ++ v.remembered) |> Enum.filter(&(&1["owner"] == owner)) |> Enum.uniq_by(& &1["id"])

  defp towers_by(v, owner, pos),
    do: Enum.filter(known_of(v, owner), &(&1["type"] == "GuardTower" and &1["completed"] != false and View.dist(View.pos(&1), pos) <= @open_cover))

  # Each opponent's read (`Swarm.Reads`) brought up to date: what we remember of their units, the
  # buildings of theirs we know, their army as we count it and their ore banked, against ours.
  # `counted` is this tick's look (`look/6`), if one got there.
  defp reads(v, memory, counted) do
    soldier = Roles.strength([%{"type" => "Soldier"}])
    ours = Roles.strength(Roles.fighters(v)) / soldier

    looked =
      case counted do
        {:at_least, owner, _} -> owner
        {owner, _} -> owner
        _ -> nil
      end

    units = (Map.values(memory.enemies) ++ v.enemy_units) |> Enum.uniq_by(& &1["id"])

    Enum.reduce(Map.keys(v.enemy_survival), {Map.get(memory, :reads, %{}), []}, fn owner, {reads, notes} ->
      theirs = Enum.filter(units, &(&1["owner"] == owner))
      count = fn type -> Enum.count(theirs, &(&1["type"] == type)) end
      known = known_of(v, owner)

      facts = %{
        army: enemy_army(memory, owner) / soldier,
        soldiers: count.("Soldier"),
        archers: count.("Archer"),
        scouts: count.("Scout"),
        trebuchets: count.("Trebuchet"),
        ccs: Enum.count(known, &(&1["type"] == "CommandCenter")),
        towers: Enum.count(known, &(&1["type"] == "GuardTower")),
        economy: Map.get(v.enemy_economy, owner, 0),
        looked: looked == owner
      }

      {reads, more} = Reads.update(reads, v.tick, owner, facts, ours, v.my_mined)
      {reads, notes ++ more}
    end)
  end

  @doc """
  The fighters we remember of player `owner` (all opponents if nil), or the most we have known of
  their army lately if that is more (`army_seen/3`). No towers.
  """
  def enemy_army(memory, owner \\ nil) do
    theirs? = &(owner == nil or &1["owner"] in [owner, nil])
    army = memory.enemies |> Map.values() |> Enum.filter(theirs?) |> Roles.strength()

    lately =
      case owner && Map.get(Map.get(memory, :army_seen, %{}), owner) do
        {most, _at} -> most
        _ -> 0
      end

    max(army, lately)
  end

  # Who we go after: the opponent the wave out is after, while they are still in; otherwise the
  # weaker of our neighbors (`Swarm.Roles.neighbors/1`; never one across the map). Weaker by survival
  # score, the ore value of everything they have alive, which the server reports for everyone.
  defp opponent(v, memory) do
    case memory.wave do
      %{owner: owner} when owner != nil and is_map_key(v.enemy_survival, owner) ->
        owner

      _ ->
        from = if v.cc, do: View.pos(v.cc), else: center(v)
        reads = Map.get(memory, :reads, %{})

        # A neighbor that reads as a boom (`Swarm.Reads`: no army to speak of, bases going up
        # without towers) comes first, the nearest: by its score it is the strongest of them, and
        # left alone until it was.
        v
        |> Roles.neighbors()
        |> Enum.min_by(fn {start, slot} -> {Reads.kind(reads, slot) != :boom, Map.get(v.enemy_survival, slot, 0), View.dist(start, from)} end, fn -> nil end)
        |> case do
          {_start, slot} -> slot
          nil -> nil
        end
    end
  end

  # Where to attack `owner`: their building nearest us (seen now, else remembered), else their start.
  defp target_of(v, owner) do
    from = if v.cc, do: View.pos(v.cc), else: center(v)
    theirs = Enum.filter(v.enemy_buildings ++ v.remembered, &(&1["owner"] == owner))
    start = Enum.find_value(v.start_owner, fn {pos, slot} -> if slot == owner, do: pos end)

    case theirs do
      [] -> start || center(v)
      _ -> theirs |> Enum.map(&View.pos/1) |> Enum.min_by(&View.dist(&1, from))
    end
  end

  # The last opponent's Command Center is left standing from the moment they are the last one,
  # whatever else they still have: killing it ends the match, and with it our score (economy is
  # all the ore we ever mined, survival all we have alive). Nothing hits it, not even the finish of
  # a nearly dead one (`Roles.finish_target/2`): a wave of 68 took one from full to dead in six ticks
  # with seven of their buildings still up, 1100 ticks early. So the wave takes everything else of
  # theirs, then camps by it (`camp`, `@camp_distance` out: farther than an
  # Archer reaches, so nobody standing there hits it on their own) and kills whatever it makes.
  # Lifted for good (`memory.spare_lifted`), into safe mode (`memory.kill`: the wave goes straight
  # for it and nothing calls it home, see `keep_wave/4` and `Swarm.UnitBrain`), when:
  # - home is losing: what is hitting a base or our workers, or an army coming, is more than home
  #   can meet (`Roles.recall/2`, `army_near_home/3`: the same tests that call a wave home) and
  #   worth `@safe_raid` or more (a smaller raid only calls the wave home, as ever), and the wave
  #   is nearer their Command Center than home. Killing it ends the match with the win and
  #   our score where it is; walking home while they wreck the base only loses it. A wave nearer
  #   home goes home, as ever.
  # - their army is back: a wave out is no longer `@margin` times what we know of their army, the
  #   same test a wave leaves on.
  # - the last `@spare_until` ticks (out of the match's own `maxTicks`).
  # Returns {the spare or nil, what to log, memory}.
  defp spare(v, memory, wave) do
    case last_cc(v, memory) do
      nil ->
        {nil, [], memory}

      _ when memory.spare_lifted ->
        {nil, [], memory}

      {owner, cc, _farm} when v.tick >= v.max_ticks - @spare_until ->
        why = "#{v.max_ticks - v.tick} ticks left: player #{owner}'s last Command Center comes down"
        {nil, [{:spare_lifted, why}], kill(memory, owner, cc)}

      # It is spared so we can go on mining. With the map mined out for certain
      # (`nothing_to_mine/2`), or with them down to it (`farm`: nobody left to keep our workers
      # from the ore), us banking nothing all the same and our workers having looked everywhere for
      # more (`ore_search/3`), there is nothing to wait for: 70 workers stood idle for 220 ticks by
      # a base we could have finished.
      {owner, cc, farm} when v.no_ore == :mined_out or (v.no_ore == :nowhere and farm) ->
        {nil, [{:spare_lifted, "nothing left to mine: player #{owner}'s last Command Center comes down"}], kill(memory, owner, cc)}

      {owner, cc, farm} ->
        alive = if wave, do: Enum.filter(v.my_units, &(&1["id"] in wave.members)), else: []
        {ours, theirs} = {Roles.strength(alive), enemy_strength(v, memory, owner)}
        losing = if wave, do: home_losing(v, memory, wave)

        cond do
          losing != nil and nearer_them?(v, alive, View.pos(cc)) ->
            why = "safe: #{losing}: player #{owner}'s last Command Center comes down instead of the wave coming home"
            {nil, [{:spare_lifted, why}], kill(memory, owner, cc)}

          wave != nil and ours < @margin * theirs ->
            why = "safe: player #{owner}'s army is back (#{round(theirs)} vs our #{round(ours)} out): their last Command Center comes down"
            {nil, [{:spare_lifted, why}], kill(memory, owner, cc)}

          true ->
            keep_spare(v, memory, owner, cc, farm)
        end
    end
  end

  defp kill(memory, owner, cc),
    do: %{memory | spare_lifted: true, spared: nil, kill: %{owner: owner, id: cc["id"], pos: View.pos(cc)}}

  # Home losing to a real army (`@safe_raid` or more), the way a wave out is called home
  # (`keep_wave/4`): "home under attack (X vs Y at home)" or "player P's army near home (X vs Y)",
  # or nil.
  defp home_losing(v, memory, wave) do
    home = Roles.recall(v, wave)
    coming = army_near_home(v, memory, wave)

    cond do
      match?({theirs, _} when theirs >= @safe_raid, home) ->
        {theirs, ours} = home
        "home under attack (#{round(theirs)} vs #{round(ours)} at home)"

      match?({_, theirs, _} when theirs >= @safe_raid, coming) ->
        {player, theirs, ours} = coming
        "player #{player}'s army near home (#{round(theirs)} vs #{round(ours)})"

      true ->
        nil
    end
  end

  # Most of the wave is nearer their Command Center than ours (we have one: `last_cc/1` needs it).
  defp nearer_them?(_v, [], _pos), do: false

  defp nearer_them?(v, alive, pos) do
    home = View.pos(v.cc)
    near = Enum.count(alive, &(View.dist(View.pos(&1), pos) < View.dist(View.pos(&1), home)))
    near * 2 >= length(alive)
  end

  # Safe mode is over once that Command Center is gone: we see where it stood, and it isn't there
  # (with a second one somewhere, the match goes on and the wave with it, as any other).
  defp forget_kill(_v, %{kill: nil} = memory), do: memory

  defp forget_kill(v, %{kill: kill} = memory) do
    there? = Enum.any?(v.enemy_buildings, &(&1["id"] == kill.id))
    if not there? and View.in_sight?(v, kill.pos), do: %{memory | kill: nil}, else: memory
  end

  # Spared: the spots by it, and what to log (when it starts, when farming starts, and any tower
  # of ours shooting it).
  defp keep_spare(v, memory, owner, cc, farm) do
    spare = Map.put(spare_spots(v, owner, cc), :farm, farm)

    hit_by_ours =
      for s <- v.tower_shots, s["owner"] == v.me, s["targetId"] == cc["id"], rem(v.tick, 10) == 0 do
        {:spare_hit, "our tower #{s["towerId"]} at #{fmt({s["fromX"], s["fromY"]})} is shooting player #{owner}'s last Command Center"}
      end

    why =
      hit_by_ours ++
        cond do
          memory.spared == {cc["id"], farm} -> []
          farm -> [{:spare, "player #{owner}'s last Command Center at #{fmt(spare.pos)} stays up: we farm until the end"}]
          true -> [{:spare, "player #{owner} is the last one: their Command Center at #{fmt(spare.pos)} stays up, the rest comes down"}]
        end

    {spare, why, %{memory | spared: {cc["id"], farm}}}
  end

  # The only opponent left and the one Command Center of theirs we know of: {owner, it, farm}.
  # `farm` when nothing they have alive can be another one, or anything much at all: their
  # survival score (the ore value of everything they have alive) less the Command Center, the
  # units of theirs we see and their other buildings we know of leaves less than a Command
  # Center's worth unaccounted for. Two known Command Centers: neither is spared (one can go and
  # the match goes on). Nor is one away from where they started while the one they started with
  # may still stand: every player starts with a Command Center there, so until we have seen that
  # spot without one (`empty_starts/2`), a Command Center elsewhere is an expansion, not their
  # last. One in the middle of the map was taken for the last, and three waves went at it with
  # nothing allowed to call them home.
  defp last_cc(%View{cc: cc, enemy_survival: survival} = v, memory) when cc != nil and map_size(survival) == 1 do
    [{owner, worth}] = Map.to_list(survival)
    known = (v.enemy_buildings ++ v.remembered) |> Enum.filter(&(&1["owner"] == owner)) |> Enum.uniq_by(& &1["id"])
    value = &Enum.sum_by(&1, fn e -> Map.get(@costs, e["type"], 0) end)
    start = Enum.find_value(v.start_owner, fn {pos, slot} -> if slot == owner, do: pos end)
    only? = fn their_cc -> start == nil or View.dist(View.pos(their_cc), start) <= 2 or start in memory.empty_starts end

    case Enum.filter(known, &(&1["type"] == "CommandCenter")) do
      [their_cc] when not is_nil(their_cc) ->
        if only?.(their_cc) do
          units = value.(Enum.filter(v.enemy_units, &(&1["owner"] == owner)))
          others = value.(Enum.filter(known, &(&1["id"] != their_cc["id"] and &1["completed"] != false)))
          {owner, their_cc, worth - @costs["CommandCenter"] - units - others < @costs["CommandCenter"]}
        end

      _ ->
        nil
    end
  end

  defp last_cc(_v, _memory), do: nil

  # Opponents' starts we can see right now with no Command Center of theirs on them (within 2),
  # added to the ones seen so before.
  defp empty_starts(v, memory) do
    ccs = for b <- v.enemy_buildings, b["type"] == "CommandCenter", do: View.pos(b)
    seen = for {start, _slot} <- v.start_owner, View.in_sight?(v, start), not Enum.any?(ccs, &(View.dist(&1, start) <= 2)), do: start
    Enum.uniq(memory.empty_starts ++ seen)
  end

  defp spare_spots(v, owner, cc) do
    pos = View.pos(cc)
    home = View.pos(v.cc)

    others =
      for b <- v.enemy_buildings ++ v.remembered, b["owner"] == owner, b["id"] != cc["id"], do: View.pos(b)

    camp = toward(pos, home, @camp_distance)
    goal = if others == [], do: camp, else: Enum.min_by(others, &{View.dist(&1, home), &1})
    %{id: cc["id"], pos: pos, goal: goal, camp: camp, siege_camp: toward(pos, home, @siege_camp_distance)}
  end

  # `@staging_distance` short of the target, on our side of it, kept on the map; and from there a
  # tile at a time back toward where the wave leaves from, until it is out of every known enemy
  # tower's reach by `@staging_clear`. Nine tiles short of their main base was inside the reach of
  # three towers of a base they had in front of it, and two Trebuchets walked there to their deaths.
  defp staging(v, {tx, ty}, {rx, ry} = from) do
    first = {clamp(tx + @staging_distance * sign(rx - tx), v.map_width), clamp(ty + @staging_distance * sign(ry - ty), v.map_height)}
    towers = Roles.enemy_towers(v)
    clear? = fn pos -> not Enum.any?(towers, &(View.dist(View.pos(&1), pos) <= Roles.range(&1) + @staging_clear)) end

    first
    |> Stream.iterate(fn {x, y} -> {x + sign(rx - x), y + sign(ry - y)} end)
    |> Enum.take(View.dist(first, from) + 1)
    |> Enum.find(first, clear?)
  end

  defp clamp(n, size), do: n |> max(0) |> min(size - 1)

  # Where guards stand: behind the Guard Tower closest to the enemy, else the rally point. With the
  # army living at a base in the middle, the guards are the ones who stay home: behind the home
  # tower closest to the enemy (within `@base_radius` of the Command Center), else by the Command
  # Center, on the enemy's side.
  defp post(v, rally, enemy) do
    forward? = forward_base(v) != nil
    home = View.pos(v.cc)

    towers =
      for t <- View.buildings_of(v, "GuardTower"), t["completed"], not forward? or View.dist(View.pos(t), home) <= @base_radius, do: t

    case towers do
      [] when forward? ->
        {x, y} = home
        {ex, ey} = enemy || center(v)
        {x + 3 * sign(ex - x), y + 3 * sign(ey - y)}

      [] ->
        rally

      towers ->
        {x, y} = towers |> Enum.map(&View.pos/1) |> Enum.min_by(&View.dist(&1, enemy))
        {cx, cy} = View.pos(v.cc)
        {x + sign(cx - x), y + sign(cy - y)}
    end
  end

  # Three tiles from the Command Center toward the middle of the map; with a base of ours in the
  # middle (`forward_base/1`), three tiles from that, toward the nearest enemy start: the army
  # lives where the ore is fought over, and its towers with it.
  defp rally(%View{} = v) do
    case forward_base(v) do
      nil ->
        home_rally(v)

      {x, y} = base ->
        {ex, ey} = Enum.min_by(v.enemy_starts, &View.dist(&1, base), fn -> center(v) end)
        {clamp(x + 3 * sign(ex - x), v.map_width), clamp(y + 3 * sign(ey - y), v.map_height)}
    end
  end

  defp home_rally(%View{cc: cc} = v) do
    {x, y} = View.pos(cc)
    {cx, cy} = center(v)
    {x + 3 * sign(cx - x), y + 3 * sign(cy - y)}
  end

  # The army living at a forward base is called home: the rally point is the main base's again
  # while enemy fighters are coming at it (within `@home_call` of the main Command Center, nearer
  # to it than to the forward base), more than those at home and the towers there can meet, and
  # all of ours with those towers are at least as strong as they are. Called once, it stays while
  # they are there and we still are; it ends `@home_call_hold` ticks after. (36 Soldiers took the
  # main Command Center and its towers from 8 guards while 39 of ours stood at the forward base:
  # by the time everyone counted, the towers were down and the fight was no longer ours.)
  # Returns {rally, memory, notes for the decision log}.
  defp home_call(%View{cc: cc} = v, memory, rally) do
    home = View.pos(cc)
    base = forward_base(v)
    last = Map.get(memory, :home_call)

    raid =
      if base,
        do: for(e <- Roles.enemy_fighters(v), d = View.dist(View.pos(e), home), d <= @home_call and d < View.dist(View.pos(e), base), do: e),
        else: []

    towers = Enum.filter(Roles.our_towers(v), &(View.dist(View.pos(&1), home) <= @home_call_base))
    fighters = Roles.home(v, memory.wave)
    there = Enum.filter(fighters, &(View.dist(View.pos(&1), home) <= @home_call_base))
    theirs = Roles.strength(raid)
    can? = raid != [] and Roles.strength(fighters ++ towers, v.me) >= theirs
    needed? = theirs > Roles.strength(there ++ towers, v.me)

    cond do
      can? and (needed? or last != nil) ->
        why = if last == nil, do: [{:home_call, "#{length(raid)} of theirs coming at the main base: the army goes home to its towers"}], else: []
        {home_rally(v), Map.put(memory, :home_call, v.tick), why}

      last != nil and raid == [] and v.tick - last < @home_call_hold ->
        {home_rally(v), memory, []}

      last != nil ->
        {rally, Map.put(memory, :home_call, nil), [{:home_call, "the army goes back to the forward base"}]}

      true ->
        {rally, memory, []}
    end
  end

  defp forward_base(v), do: View.forward_base(v)
  defp middle?(v, pos), do: View.middle?(v, pos)

  defp center(%View{} = v), do: {div(v.map_width, 2), div(v.map_height, 2)}

  # Where attacks come from: our neighbors' starts, or the middle of the map with none left.
  defp threat_points(v) do
    case Roles.neighbors(v) do
      [] -> [center(v)]
      neighbors -> Enum.map(neighbors, &elem(&1, 0))
    end
  end

  defp dist2({x1, y1}, {x2, y2}), do: (x1 - x2) ** 2 + (y1 - y2) ** 2

  # Which way the next tower faces: the start of the nearest neighbor still in that no tower of
  # ours faces yet (or faces the least), so towers spread over the ways in. The middle of the
  # map with no neighbor left. A tower faces a start when it is near the base and closer to it.
  defp front(%View{cc: cc} = v) do
    home = View.pos(cc)

    towers =
      for t <- View.buildings_of(v, "GuardTower"), View.dist(View.pos(t), home) <= 6, do: View.pos(t)

    faced = fn start -> Enum.count(towers, &(View.dist(&1, start) < View.dist(home, start))) end

    case Roles.neighbors(v) do
      [] -> center(v)
      neighbors -> neighbors |> Enum.min_by(fn {start, slot} -> {faced.(start), View.dist(home, start), slot} end) |> elem(0)
    end
  end

  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(_), do: 0

  ## Buildings

  # Forget the pending building once it is up, or if it isn't coming: the builder died, its
  # order failed, or it is taking too long.
  defp still_pending(p, %View{} = v) do
    failed? =
      Enum.any?(v.events, fn e ->
        e["kind"] == "CommandFailed" and e["entityId"] == p.builder and (e["tick"] || 0) >= p.at
      end)

    cond do
      count(v, p.type) > p.had -> nil
      View.my_unit(v, p.builder) == nil -> nil
      failed? -> nil
      v.tick - p.at > @build_timeout_ticks -> nil
      true -> p
    end
  end

  # The pending building, kept or forgotten (`still_pending/2`); one forgotten without having
  # appeared failed: a strike against its site.
  defp settle_pending(%{pending: nil} = memory, _v), do: memory

  defp settle_pending(%{pending: p} = memory, v) do
    case still_pending(p, v) do
      nil -> if count(v, p.type) > p.had, do: %{memory | pending: nil}, else: strike(%{memory | pending: nil}, v, Map.get(p, :site))
      kept -> %{memory | pending: kept}
    end
  end

  # Building failed at `spot` (`times` over): remembered for `@avoid_lost_ticks`. Not at home (within
  # `@base_radius` of the Command Center): a raid on the base is no reason to build elsewhere.
  defp strike(memory, v, spot, times \\ 1)
  defp strike(memory, _v, nil, _times), do: memory

  defp strike(memory, v, spot, times) do
    if v.cc != nil and View.dist(spot, View.pos(v.cc)) <= @base_radius do
      memory
    else
      %{memory | strikes: Map.update(memory.strikes, spot, List.duplicate(v.tick, times), &(List.duplicate(v.tick, times) ++ &1))}
    end
  end

  # The spots building keeps failing at (`@site_strikes` strikes in the last `@avoid_lost_ticks`).
  defp blocked(memory, v) do
    for {spot, ticks} <- memory.strikes, Enum.count(ticks, &(v.tick - &1 <= @avoid_lost_ticks)) >= @site_strikes, do: spot
  end

  # A site nobody is working on (its builder died or was called away) gets the closest free
  # worker. Its cost was paid when it was started, so this needs no ore. Not a site at a blocked
  # spot (`@site_strikes`): workers sent there keep coming back or dying; it waits.
  defp finish_sites({cmds, mem, ore}, v) do
    unfinished = Enum.reject(v.my_buildings, &(&1["completed"] or View.pos(&1) in v.blocked))
    worked_on = MapSet.new(View.units_of(v, "Worker"), & &1["targetId"])
    # Forget sites that are finished or gone.
    helpers = Map.take(mem.helpers, Enum.map(unfinished, & &1["id"]))

    {cmds, helpers} =
      Enum.reduce(unfinished, {cmds, helpers}, fn b, {cmds, helpers} ->
        sent_recently? =
          case helpers[b["id"]] do
            {_worker, at} -> v.tick - at <= @help_wait_ticks
            nil -> false
          end

        free = free_workers(v, %{mem | helpers: helpers})

        if MapSet.member?(worked_on, b["id"]) or sent_recently? or free == [] do
          {cmds, helpers}
        else
          worker = closest(free, View.pos(b))
          {[build_cmd([worker], b["type"], View.pos(b)) | cmds], Map.put(helpers, b["id"], {worker["id"], v.tick})}
        end
      end)

    # Each worker sent is a strike against the site: whoever was building it left or died.
    sent = for {id, {_worker, at}} <- helpers, at == v.tick, b = Enum.find(unfinished, &(&1["id"] == id)), b != nil, do: View.pos(b)
    mem = Enum.reduce(sent, mem, &strike(&2, v, &1))

    {cmds, %{mem | helpers: helpers}, ore}
  end

  # Waiting on a building: keep its ore aside. Otherwise order the next one in the build order,
  # or start saving for it.
  defp build({cmds, %{pending: %{type: type}} = mem, ore}, _v, _terrain),
    do: {cmds, mem, ore - @costs[type]}

  defp build({cmds, mem, ore} = acc, v, terrain) do
    case next_build(v, terrain, mem) do
      nil -> acc
      {type, site} -> if ore >= @costs[type], do: order(acc, v, type, site), else: {cmds, mem, ore - @costs[type]}
    end
  end

  # A base Command Center (`base_cc/3`) is ordered the tick we can pay for it, apart from the rest
  # of the building (`mem.base_order`): its builders may walk 50 tiles, and nothing else waits for
  # them. Its 400 is held back while they walk (`plan/3`): the game takes it when they break ground.
  defp found_base({cmds, %{base_order: nil} = mem, ore} = acc, v, terrain) do
    with {"CommandCenter", site, :base} <- base_cc(v, terrain, mem),
         true <- ore >= @costs["CommandCenter"],
         [_ | _] = free <- free_workers(v, mem) do
      builders = closest_first(free, site) |> Enum.take(@base_builders)
      order = %{site: site, builders: Enum.map(builders, & &1["id"]), at: v.tick}
      {[build_cmd(builders, "CommandCenter", site) | cmds], %{mem | base_order: order, bases: Enum.uniq([site | mem.bases])}, ore - @costs["CommandCenter"]}
    else
      _ -> acc
    end
  end

  defp found_base(acc, _v, _terrain), do: acc

  # Three or four players: two or three opponents around a middle everyone wants.
  defp contested?(%View{players: players}), do: players in 3..4

  # Where our base Command Center in the middle stands, finished or going up, or nil.
  defp middle_base(v) do
    Enum.find_value(View.buildings_of(v, "CommandCenter"), fn b ->
      if View.base?(v, b) and middle?(v, View.pos(b)), do: View.pos(b)
    end)
  end

  # Our first base comes ahead of the army floor (`army_floor/3`), and the ore is kept for it while
  # we are short of its price: with the floor at their army and our income theirs, nothing was ever
  # left for one. We ended on 43 workers and one base against 64 on four.
  defp first_base({_cmds, %{base_order: nil}, _ore} = acc, v, terrain) do
    if Enum.any?(View.buildings_of(v, "CommandCenter"), &View.base?(v, &1)) do
      acc
    else
      case found_base(acc, v, terrain) do
        # Short of it: each Barracks keeps one in its queue (`train_army/3`: nothing is trained any
        # later for it), and the rest of the ore waits.
        {_cmds, %{base_order: nil} = mem, ore} = short when ore < 400 ->
          if base_cc(v, terrain, mem) do
            {cmds, mem, ore} = train_army(short, v, terrain)
            {cmds, mem, min(ore, 0)}
          else
            short
          end

        other ->
          other
      end
    end
  end

  defp first_base(acc, _v, _terrain), do: acc

  # Whether a base is wanted and we can't pay for it yet: then each Barracks keeps one in its
  # queue and no more (`train_army/3`), and what that leaves in the bank adds up to its 400.
  # Nothing is trained any later for it; workers, buildings and research never wait.
  defp saving_for_base?({_cmds, %{base_order: nil} = mem, ore}, v, terrain),
    do: ore < @costs["CommandCenter"] and base_cc(v, terrain, mem) != nil

  defp saving_for_base?(_acc, _v, _terrain), do: false

  # The base on its way: forgotten once it has broken ground (a Command Center stands on its site);
  # given up, with a strike against the site, if its builders are all dead, one reports the order
  # failed, or `@base_timeout` has passed.
  defp settle_base(%{base_order: nil} = memory, _v), do: memory

  defp settle_base(%{base_order: order} = memory, v) do
    up? = Enum.any?(View.buildings_of(v, "CommandCenter"), &(View.pos(&1) == order.site))
    alive = Enum.filter(order.builders, &(View.my_unit(v, &1) != nil))
    failed? = Enum.any?(v.events, &(&1["kind"] == "CommandFailed" and &1["entityId"] in order.builders and (&1["tick"] || 0) >= order.at))

    cond do
      up? -> %{memory | base_order: nil}
      alive == [] or failed? or v.tick - order.at > @base_timeout -> strike(%{memory | base_order: nil}, v, order.site)
      true -> memory
    end
  end

  # Free workers go build it (see `builders/4`); we remember the first so we can tell if the order
  # fails. With no free worker, keep the ore aside and try again next tick.
  defp order({cmds, mem, ore}, v, type, site) do
    case free_workers(v, mem) do
      [] ->
        {cmds, mem, ore - @costs[type]}

      free ->
        builders = builders(v, free, type, site)
        pending = %{type: type, builder: hd(builders)["id"], at: v.tick, had: count(v, type), site: site}
        {[build_cmd(builders, type, site) | cmds], %{mem | pending: pending}, ore - @costs[type]}
    end
  end

  # Every worker next to a site adds 1 work a tick, so builders add up. Who builds:
  # - a depot: the workers mining ore it will serve (within reach of the site), up to
  #   `@depot_builders`. They are there already and are the ones it saves the walk, so it goes up
  #   in a few ticks. With nobody mining there yet, as below.
  # - the first Barracks: the `@first_barracks_builders` closest; everything military waits on it.
  # - anything else: the closest (the two closest when rich).
  defp builders(v, free, "ResourceDepot", site) do
    by_id = Map.new(v.deposits, &{&1["id"], &1})

    users =
      for w <- free,
          w["activity"] in ["Gathering", "Returning"],
          d = by_id[w["targetId"]],
          d != nil and View.dist(View.pos(d), site) <= View.drop_off_reach(),
          do: w

    first? = count(v, "ResourceDepot") == 0

    case users do
      [] -> closest_first(free, site) |> Enum.take(if(first?, do: @first_depot_builders, else: usual_builders(v)))
      users -> closest_first(users, site) |> Enum.take(@depot_builders)
    end
  end

  # The backup Command Center: 80 work, two builders. (A base gets `@base_builders`, see `build/3`.)
  defp builders(_v, free, "CommandCenter", site), do: closest_first(free, site) |> Enum.take(2)

  defp builders(v, free, "Barracks", site) do
    n = if count(v, "Barracks") == 0, do: @first_barracks_builders, else: usual_builders(v)
    closest_first(free, site) |> Enum.take(n)
  end

  # The first Tech Lab: two builders, so it is up in 20 ticks, not 40, and Harvesting1 with it.
  defp builders(v, free, "TechLab", site) do
    n = if count(v, "TechLab") == 0, do: @first_lab_builders, else: usual_builders(v)
    closest_first(free, site) |> Enum.take(n)
  end

  defp builders(v, free, _type, site), do: closest_first(free, site) |> Enum.take(usual_builders(v))

  defp usual_builders(v), do: if(rich?(v), do: 2, else: 1)

  defp closest_first(workers, site), do: Enum.sort_by(workers, &{View.dist(View.pos(&1), site), &1["id"]})

  defp rich?(v), do: v.ore >= @rich and Enum.any?(View.buildings_of(v, "Barracks"), & &1["completed"])

  # Workers we can pull off mining: not building, not on their way to a site, and not already
  # sent somewhere by us. Taking a builder would leave its building unfinished.
  defp free_workers(v, mem) do
    sites = for b <- v.my_buildings, not b["completed"], into: MapSet.new(), do: b["id"]
    sent = for {_site, {worker, _at}} <- mem.helpers, into: MapSet.new(), do: worker
    sent = if mem.pending, do: MapSet.put(sent, mem.pending.builder), else: sent
    sent = if mem.base_order, do: MapSet.union(sent, MapSet.new(mem.base_order.builders)), else: sent
    sent = if mem.barracks_order, do: MapSet.put(sent, mem.barracks_order.builder), else: sent

    Enum.reject(View.units_of(v, "Worker"), fn w ->
      w["activity"] == "Building" or MapSet.member?(sites, w["targetId"]) or MapSet.member?(sent, w["id"])
    end)
  end

  defp closest(units, pos), do: Enum.min_by(units, &{View.dist(View.pos(&1), pos), &1["id"]})

  defp build_cmd(workers, type, {x, y}),
    do: %{"type" => "Build", "unitIds" => Enum.map(workers, & &1["id"]), "buildingType" => type, "x" => x, "y" => y}

  # A new drop-off if our ore is running out, else the first building we are short of, once we
  # have the workers and prerequisites for it. One we can't find room for is skipped so it
  # doesn't hold up the rest.
  defp next_build(%View{cc: nil}, _terrain, _mem), do: nil

  defp next_build(%View{} = v, terrain, mem) do
    depot = if may_expand?(v, mem), do: conquest_depot(v, terrain, mem) || remote_depot(v, terrain, mem) || expansion(v, terrain, mem)

    case depot do
      nil ->
        # In a big game a co-op's tower comes before the rest: outposts are where raiders go.
        second_lab(v, terrain) ||
          if big?(v) or contested?(v),
            do:
              outpost_tower(v, terrain) || from_build_order(v, terrain, avoid(v, mem)) ||
                siege_workshop(v, terrain) || extra(v, terrain),
            else:
              from_build_order(v, terrain, avoid(v, mem)) || outpost_tower(v, terrain) ||
                siege_workshop(v, terrain) || extra(v, terrain)

      site ->
        {"ResourceDepot", site}
    end
  end

  # In a big game the first wave waits for the square of towers: how many we have (finished or
  # going up) while short of it, else nil. Not forever: past `@square_deadline`, it goes anyway.
  defp towers_short(v, memory) do
    n = count(v, "GuardTower")
    if big?(v) and not medium?(v) and memory.next_wave == 1 and n < @big_towers and v.tick < @square_deadline, do: n
  end

  # A big game: started with `@big_game` players or more.
  defp big?(%View{players: players}), do: players >= @big_game

  # A medium game: big (`@big_game` players or more) but under `@huge_game`. Two neighbors on top of
  # us and home ore gone by about tick 450: army first, a few towers, take the weaker neighbor and
  # its ore. The big game's tower square is for the 10+ player games it was made for.
  defp medium?(%View{players: players}), do: players >= @big_game and players < @huge_game

  # The build order as {type, how many, workers first, where, fighters first}.
  defp build_order(v) do
    order =
      cond do
        medium?(v) -> @medium_build_order
        big?(v) -> @big_build_order
        true -> @build_order
      end

    for entry <- order do
      case entry do
        {type, wanted, workers, where} -> {type, wanted, workers, where, 0}
        full -> full
      end
    end
  end

  # The usual number, and more while there is ore for them (`@ore_per_worker`).
  # None with nothing left to mine (`View.no_ore`, see `nothing_to_mine/2`): the ore goes to the army.
  defp target_workers(%View{no_ore: no_ore}) when no_ore != false, do: 0

  defp target_workers(v) do
    usual = if big?(v), do: @big_target_workers, else: @target_workers
    v |> minable_ore() |> div(@ore_per_worker) |> min(@max_workers) |> max(usual)
  end

  # The ore left that we can get at: by our drop-offs, or free to take (`View.claimable?/2`) and
  # not in reach of an enemy tower.
  defp minable_ore(v) do
    near = MapSet.new(View.near_deposits(v), & &1["id"])

    v.deposits
    |> Enum.filter(fn d ->
      MapSet.member?(near, d["id"]) or (View.claimable?(v, View.pos(d)) and not Roles.under_tower?(v, View.pos(d)))
    end)
    |> Enum.sum_by(&(&1["remaining"] || 0))
  end

  # A new co-op away from home, in a big game only with an army to hold it; or with home short of
  # ore for a while (`@short_for_ticks`), army or not: the choice then is a depot that may be lost
  # or every worker idle for the rest of the game.
  defp may_expand?(v, mem), do: not big?(v) or length(Roles.fighters(v)) >= @expand_army or short_long_enough?(v, mem)

  defp short_long_enough?(v, mem), do: mem.ore_short_since != nil and v.tick - mem.ore_short_since >= @short_for_ticks

  # A big game's first wave may go early, with `@early_min` attackers and before the tower square,
  # at a neighbor that is close (its start within `@early_reach`), that a scout has just looked at,
  # and that is weak: our attackers at least `@early_margin` times all we know of it.
  defp early_strike?(v, memory, owner, staged, ours, theirs) do
    start = Enum.find_value(v.start_owner, fn {pos, slot} -> if slot == owner, do: pos end)

    big?(v) and memory.next_wave == 1 and v.cc != nil and start != nil and
      View.dist(start, View.pos(v.cc)) <= @early_reach and fresh?(memory.look, owner, v) and
      length(staged) >= @early_min and ours >= @early_margin * theirs
  end

  # The fewest attackers a wave may leave with (see `@min_wave`).
  defp wave_min(v, memory) do
    cond do
      medium?(v) and memory.next_wave == 1 -> @medium_first_wave
      medium?(v) -> @min_wave
      big?(v) and memory.next_wave == 1 -> @big_first_wave
      big?(v) -> @big_min_wave
      true -> @min_wave
    end
  end

  # The next base Command Center, as {"CommandCenter", site, :base}, or nil: one more than we have
  # at each of `@cc_at_workers` workers, with a Barracks up and none going up already, by the best
  # field worth one (`base_fields/2`).
  defp base_cc(v, terrain, mem) do
    workers = length(View.units_of(v, "Worker"))
    wanted = 1 + Enum.count(@cc_at_workers, &(workers >= &1))
    ccs = View.buildings_of(v, "CommandCenter")

    with true <- length(ccs) < wanted,
         true <- length(Roles.fighters(v)) >= @base_army,
         true <- mem.base_order == nil,
         true <- may_expand?(v, mem),
         true <- Enum.all?(ccs, & &1["completed"]),
         true <- Enum.any?(View.buildings_of(v, "Barracks"), & &1["completed"]),
         [_ | _] = field <- next_base_field(v, mem) do
      # The site is chosen with the ore we infer there counted as ore: nothing goes up on a pile.
      with_inferred = %{v | deposits: v.deposits ++ inferred_ore(mem, v)}

      case by_field(terrain, with_inferred, hd(field)) do
        {_, _} = site -> {"CommandCenter", site, :base}
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  # The fields worth a base, best first, each as its deposits (seen, remembered or inferred):
  # `@base_ore` or more in it, none of our drop-offs by it (finished or going up), not where
  # building keeps failing (`avoid/2`), and clear of every living enemy (`clear_of_enemies?/3`). An
  # eliminated player's start first. Then the safest (`@safe_enough`), the nearest of those first.
  # (`base_fields/2` keeps the ones a unit of ours has seen in the last `@clear_for` ticks.)
  defp base_fields(v, mem) do
    Enum.filter(base_candidates(v, mem), fn field ->
      at = mem.checked[View.pos(hd(field))]
      at != nil and v.tick - at <= @clear_for
    end)
  end

  # The field the next base goes by: the best one a unit of ours has seen lately (`base_fields/2`).
  # But with three or four players it goes by the nearest field (the best there, `base_candidates/2`)
  # and no other: until a scout has seen that one (it is sent there, `survey/3`), none goes up. A
  # scout on its way to look at an opponent had seen a field across the map, between the other
  # two players, and the base went there, 50 tiles from home, with the one 18 tiles away unseen.
  # (With no scout alive, any seen field as before.)
  defp next_base_field(v, mem) do
    seen = base_fields(v, mem)

    case base_candidates(v, mem) do
      [best | _] ->
        nearest_only? = contested?(v) and View.units_of(v, "Scout") != []
        if nearest_only?, do: Enum.find(seen, &(&1 == best)), else: List.first(seen)

      [] ->
        nil
    end
  end

  # Whether we are short of a Command Center for our workers (`@cc_at_workers`), with none on its way.
  defp base_wanted?(v, mem) do
    workers = length(View.units_of(v, "Worker"))
    mem.base_order == nil and length(View.buildings_of(v, "CommandCenter")) < 1 + Enum.count(@cc_at_workers, &(workers >= &1))
  end

  # The fields worth a base as far as we know, best first, seen lately or not.
  defp base_candidates(%View{cc: nil}, _mem), do: []

  defp base_candidates(v, mem) do
    home = View.pos(v.cc)
    ore = v.deposits ++ inferred_ore(mem, v)
    ours = for b <- v.my_buildings, b["type"] in ["CommandCenter", "ResourceDepot"], do: View.pos(b)
    avoid = avoid(v, mem)
    theirs = v.enemy_starts ++ Enum.map(v.enemy_buildings ++ v.remembered, &View.pos/1)
    middle = center(v)

    safety = fn pos ->
      from_them = theirs |> Enum.map(&View.dist(&1, pos)) |> Enum.min(fn -> 99 end)
      min(min(from_them, 2 * View.dist(pos, middle)), @safe_enough)
    end

    # With three or four players the nearest field comes first, the middle like any other, and
    # none farther from home than the middle is (by `@base_slack`) while every opponent is still
    # in. Two house bots each took the field nine tiles from their base; we took the middle 25
    # tiles off and then one 41 tiles off, with the one nine tiles from ours left to last, and
    # had 34 Soldiers at one and 22 at the other when 75 came.
    too_far? = fn pos -> contested?(v) and v.fallen_starts == [] and View.dist(pos, home) > View.dist(middle, home) + @base_slack end

    # Otherwise, until we have a base in the middle (`@forward_towers`), finished or going up, the
    # fields there come first.
    ours_middle? = Enum.any?(View.buildings_of(v, "CommandCenter"), &(View.base?(v, &1) and middle?(v, View.pos(&1))))

    ore
    |> fields()
    |> Enum.filter(fn field ->
      center = View.pos(hd(field))

      Enum.sum_by(field, &(&1["remaining"] || 0)) >= @base_ore and
        not Enum.any?(field, fn d -> Enum.any?(ours, &(View.dist(&1, View.pos(d)) <= View.drop_off_reach())) end) and
        not Enum.any?(avoid, &(View.dist(&1, center) <= 4)) and
        Enum.all?(field, &clear_of_enemies?(v, mem, View.pos(&1)))
    end)
    |> Enum.reject(fn field -> too_far?.(View.pos(hd(field))) end)
    |> Enum.sort_by(fn field ->
      center = View.pos(hd(field))
      fallen? = Enum.any?(v.fallen_starts, &(View.dist(&1, center) <= @conquest_reach))
      wanted_middle? = not contested?(v) and not ours_middle? and middle?(v, center)

      if contested?(v),
        do: {not fallen?, View.dist(center, home), center},
        else: {not fallen?, not wanted_middle?, if(wanted_middle?, do: 0, else: -safety.(center)), View.dist(center, home), center}
    end)
  end

  # Deposits grouped into fields: each with the ones within 4 tiles of it, the pile nearest our
  # Command Center first (so every field is found from that pile).
  defp fields(ore) do
    Enum.reduce(Enum.sort_by(ore, &{&1["x"], &1["y"]}), [], fn d, fields ->
      case Enum.find_index(fields, fn field -> Enum.any?(field, &(View.dist(View.pos(&1), View.pos(d)) <= 4)) end) do
        nil -> fields ++ [[d]]
        i -> List.update_at(fields, i, &(&1 ++ [d]))
      end
    end)
  end

  # Nothing of a living enemy's near `pos`: `@base_clear` tiles from their starts and the buildings
  # of theirs we know of, out of their towers' reach, and `@base_watch` from their fighters we see
  # or remember.
  defp clear_of_enemies?(v, mem, pos) do
    fighters = Map.values(mem.enemies) ++ Enum.filter(v.enemy_units, &(&1["type"] not in ["Worker", "Scout"]))

    Enum.all?(v.enemy_starts, &(View.dist(&1, pos) >= @base_clear)) and
      Enum.all?(v.enemy_buildings ++ v.remembered, &(View.dist(View.pos(&1), pos) >= @base_clear)) and
      not Roles.under_tower?(v, pos) and
      not Enum.any?(fighters, &(View.dist(View.pos(&1), pos) <= @base_watch))
  end

  # Workers mining a field with a walk to a drop-off longer than `@depot_walk` (a depot finished or
  # going up counts): a depot by the field the most of them are at, if that is `@remote_miners` or
  # more. With a depot right by their ore they mine and bank without walking; 30 stacked workers
  # each walking 9 tiles (still "in reach") spent most of a game walking. A depot is the price of
  # one Soldier, so it doesn't wait for anything else.
  defp remote_depot(v, terrain, mem) do
    avoid = avoid(v, mem)
    # The home ore waits for the build order's own depot (after the first Barracks).
    first_depot? = View.buildings_of(v, "ResourceDepot") == []

    far =
      for w <- View.units_of(v, "Worker"),
          w["activity"] in ["Gathering", "Returning", "Moving"],
          d = Enum.find(v.deposits, &(&1["id"] == w["targetId"])),
          d != nil and walk(v, d) > @depot_walk,
          not (first_depot? and View.dist(View.pos(d), View.pos(v.cc)) <= View.drop_off_reach()),
          do: d

    with [_ | _] <- far,
         target = Enum.max_by(far, fn d -> {Enum.count(far, &(View.dist(View.pos(&1), View.pos(d)) <= 4)), -d["id"]} end),
         true <- Enum.count(far, &(View.dist(View.pos(&1), View.pos(target)) <= 4)) >= @remote_miners,
         true <- field_ore(v, target) >= @depot_ore,
         false <- Enum.any?(avoid, &(View.dist(&1, View.pos(target)) <= 4)),
         # The middle gets a base with towers, not a bare depot.
         false <- contested?(v) and middle?(v, View.pos(target)) and middle_base(v) == nil do
      right_by(terrain, v, target)
    else
      _ -> nil
    end
  end

  # The ore left in the field around `target` (the deposits a depot by it serves, see `by_field/3`).
  defp field_ore(v, target),
    do: v.deposits |> Enum.filter(&(View.dist(View.pos(&1), View.pos(target)) <= 4)) |> Enum.sum_by(&(&1["remaining"] || 0))

  # How far a deposit is from the closest drop-off, finished or a depot going up.
  defp walk(v, deposit) do
    sites = for b <- View.buildings_of(v, "ResourceDepot"), not b["completed"], do: View.pos(b)
    (View.drop_offs(v) ++ sites) |> Enum.map(&View.dist(&1, View.pos(deposit))) |> Enum.min(fn -> 99 end)
  end

  # A medium game: a neighbor we eliminated left its ore by its start (no longer enemy ground, see
  # `View.fallen_starts`). A depot goes there as soon as we can, the side of its field nearest us,
  # and like every outpost it gets a tower (`outpost_tower/2`): a second base in a corner next to
  # us, not out in the middle of the map, where every army passes. Nil if there is none to take.
  defp conquest_depot(v, terrain, mem) do
    home = View.pos(v.cc)
    ours = View.drop_offs(v) ++ for(b <- View.buildings_of(v, "ResourceDepot"), not b["completed"], do: View.pos(b))
    avoid = avoid(v, mem)

    fields =
      for start <- v.fallen_starts,
          field = Enum.filter(v.deposits, &(View.dist(View.pos(&1), start) <= @conquest_reach)),
          field != [],
          not Enum.any?(field, fn d -> Enum.any?(ours, &(View.dist(&1, View.pos(d)) <= View.drop_off_reach())) end),
          target = Enum.min_by(field, &{View.dist(View.pos(&1), home), &1["id"]}),
          not Enum.any?(avoid, &(View.dist(&1, View.pos(target)) <= 4)),
          do: target

    if medium?(v) and fields != [] do
      by_field(terrain, v, Enum.min_by(fields, &{View.dist(View.pos(&1), home), &1["id"]}))
    end
  end

  # Home has been short of ore for a while: a depot by the closest other ore.
  defp expansion(v, terrain, mem) do
    # A site at a blocked spot isn't one going up: it waits, and the next depot goes elsewhere.
    building_one? = Enum.any?(View.buildings_of(v, "ResourceDepot"), &(not &1["completed"] and View.pos(&1) not in v.blocked))

    if short_long_enough?(v, mem) and not building_one?, do: site(terrain, v, :expansion, avoid(v, mem))
  end

  # Where we lost a building lately (`mem.lost`) and enemy fighters we know of are still near (within
  # `@lost_clear`): no new depot or building there yet. Once they are gone, we build again: a lost
  # depot by the only ore left otherwise has every worker walking to the Command Center for good.
  defp avoid(v, mem) do
    enemies = for {_id, e} <- mem.enemies, e["type"] not in ["Worker", "Scout"], do: View.pos(e)
    enemies = enemies ++ for(e <- v.enemy_units, e["type"] not in ["Worker", "Scout"], do: View.pos(e))

    # Blocked spots too, enemies in sight or not: what kills a site there may be a tower in the fog.
    v.blocked ++ for(spot <- Map.keys(mem.lost), Enum.any?(enemies, &(View.dist(&1, spot) <= @lost_clear)), do: spot)
  end

  # A building of ours that was there last tick and isn't now was destroyed: remember the spot.
  defp remember_losses(memory, v) do
    now = Map.new(v.my_buildings, &{&1["id"], View.pos(&1)})
    gone = memory.buildings |> Map.drop(Map.keys(now)) |> Map.values()

    lost =
      memory.lost
      |> Map.merge(Map.new(gone, &{&1, v.tick}))
      |> Map.reject(fn {_spot, at} -> v.tick - at > @avoid_lost_ticks end)

    # Old strikes are forgotten; a building destroyed is two against its spot.
    strikes =
      for {spot, ticks} <- memory.strikes, recent = Enum.filter(ticks, &(v.tick - &1 <= @avoid_lost_ticks)), recent != [], into: %{}, do: {spot, recent}

    memory = %{memory | buildings: now, lost: lost, strikes: strikes, hp: Map.new(v.my_buildings, &{&1["id"], &1["hp"]})}
    Enum.reduce(gone, memory, &strike(&2, v, &1, 2))
  end

  # Since when home has been short of ore (see `@low_home_ore`), or nil if it isn't.
  defp short_since(_memory, %View{cc: nil}), do: nil

  defp short_since(memory, v) do
    near = View.near_deposits(v)
    ore_left = Enum.sum_by(near, &(&1["remaining"] || 0))

    # Ore actually left, not workers per deposit: they stack, so a crowded field isn't running out.
    low = max(@low_home_ore, @low_ore_per_worker * length(View.units_of(v, "Worker")))

    if ore_left < low,
      do: memory.ore_short_since || v.tick,
      else: nil
  end

  # Below the floor, the Barracks train before anything is built or researched.
  defp army_floor(acc, v, memory) do
    fighters = Roles.fighters(v)

    if length(fighters) < @army_floor + div(v.tick, @army_floor_ticks) or Roles.strength(fighters) < flood_floor(v, memory),
      do: train_army(acc, v, nil),
      else: acc
  end

  # With two neighbors that read as floods (`Swarm.Reads`), the floor is the bigger army of the
  # two as we know it: until ours is that, the Barracks are
  # fed before anything else is built or researched. Among five of them we had 31 fighters at
  # tick 300 to their 48 to 56 each, on the same workers: the difference had gone into research,
  # depots, a second Tech Lab and a base, and the first raid took the Barracks and the workers.
  #
  # The floor is also the biggest army of any opponent still in going by the scoreboard
  # (`army_by_score/2`), from tick `@score_floor_from`, in every game: no look or read needed. The read of a flood came at tick 300, a tick after 37 Soldiers were
  # at our towers with 25 of ours home.
  # As a strength; 0 otherwise.
  defp flood_floor(v, memory) do
    reads = Map.get(memory, :reads, %{})
    neighbors = Roles.neighbors(v)
    floods = for {_start, slot} <- neighbors, Reads.kind(reads, slot) == :flood, do: enemy_army(memory, slot)
    by_reads = if length(floods) >= 2, do: Enum.max(floods), else: 0

    # Every opponent still in, whatever the number of players: one on one the floor was 10
    # fighters at tick 400 and everything else came first; our four Barracks trained nothing for
    # 25 ticks with 500 ore banked, and we had 12 Soldiers to 41.
    by_score =
      if v.tick >= @score_floor_from,
        do: v.start_owner |> Map.values() |> Enum.map(&army_by_score(v, &1)) |> Enum.max(fn -> 0 end),
        else: 0

    # No limit to it: capped at 40 and then 80 Soldiers' worth, we stopped keeping up just when
    # their army got big.
    max(by_reads, by_score)
  end

  defp from_build_order(v, terrain, avoid) do
    workers = length(View.units_of(v, "Worker"))

    fighters = length(Roles.fighters(v))

    v
    |> build_order()
    |> Enum.filter(fn {type, wanted, _, _, _} -> count(v, type) < wanted end)
    |> Enum.reduce_while(nil, fn {type, _wanted, min_workers, where, min_fighters}, nil ->
      gated? = workers < min_workers

      cond do
        # Not before the army is this big: skip it, and keep the ore for soldiers.
        fighters < min_fighters -> {:cont, nil}
        # Towers wait for the economy (`@tower_from`); the rest of the order goes on.
        type == "GuardTower" and v.tick < @tower_from -> {:cont, nil}
        not prerequisites?(v, type) -> {:halt, nil}
        gated? and not rich?(v) -> {:halt, nil}
        # Rich, a depot still waits for its workers; the rest of the order goes on.
        gated? and type == "ResourceDepot" -> {:cont, nil}
        (site = site(terrain, v, where, avoid)) && clear_of_spared?(v, type, site) -> {:halt, {type, site}}
        true -> {:cont, nil}
      end
    end)
  end

  # An outpost without a Guard Tower (finished or not) near it gets one, and a second once we are
  # rich: towers are the cheapest defense there is, and outposts are where raiders go. Needs a
  # finished Barracks, like every tower; the first doesn't need us to be rich.
  defp outpost_tower(v, terrain) do
    towers = Enum.map(View.buildings_of(v, "GuardTower"), &View.pos/1)
    # With three or four players a base's towers start with its Command Center, not once it is up.
    going_up =
      if contested?(v),
        do: for(b <- View.buildings_of(v, "CommandCenter"), not b["completed"], View.base?(v, b), do: View.pos(b)),
        else: []

    bases = View.base_ccs(v) ++ going_up
    # A base Command Center gets `@base_towers` whether we are rich or not; the one in the middle,
    # where the army lives, `@forward_towers`.
    wanted = fn o ->
      cond do
        o in bases and middle?(v, o) -> @forward_towers
        o in bases -> @base_towers
        rich?(v) -> @outpost_towers
        true -> 1
      end
    end

    if prerequisites?(v, "GuardTower") do
      (going_up ++ Roles.outposts(v))
      |> Enum.reject(fn o -> Enum.count(towers, &(View.dist(&1, o) <= @outpost_tower_reach)) >= wanted.(o) end)
      |> Enum.find_value(fn o ->
        site = site(terrain, v, {:outpost, o})
        if site && clear_of_spared?(v, "GuardTower", site), do: {"GuardTower", site}
      end)
    end
  end

  # The army is big enough and SiegeEngineering is done: a SiegeWorkshop, if we have none.
  defp siege_workshop(v, terrain) do
    if count(v, "SiegeWorkshop") == 0 and siege_time?(v) and prerequisites?(v, "SiegeWorkshop") do
      site = site(terrain, v, :base)
      site && {"SiegeWorkshop", site}
    end
  end

  defp siege_time?(v), do: length(Roles.fighters(v)) >= @siege_after_fighters

  # Rich, with the build order done: the first extra we are short of and have room for.
  defp extra(v, terrain) do
    done? = Enum.all?(build_order(v), fn {type, wanted, _, _, _} -> count(v, type) >= wanted end)

    if rich?(v) and done? do
      Enum.find_value(@extras, fn {type, wanted, where} ->
        if count(v, type) < wanted and prerequisites?(v, type) do
          site = site(terrain, v, where)
          site && {type, site}
        end
      end)
    end
  end

  defp second_lab(v, terrain) do
    labs = View.buildings_of(v, "TechLab")

    if length(labs) == 1 and hd(labs)["completed"] and length(View.units_of(v, "Worker")) >= @second_lab_workers do
      site = site(terrain, v, :base)
      site && {"TechLab", site}
    end
  end

  # Another Barracks whenever every one we have is busy (finished, two or more queued: the ore is
  # there to keep them all training) and we have the ore for it now, after whatever else is being
  # built or saved for, rich or not, build order done or not, up to `@max_barracks`. On its own
  # order (`barracks_order`): it doesn't wait for the building in `pending`, nor hold it up. Never
  # saved up for. By the main Command Center, or by a base one when there is no room left there.
  #
  # Catching up (`catch_up?`: our army under the flood floor, `flood_floor/2`): up to
  # `@max_barracks` of them come first, right after the fighters and ahead of every other
  # building, base and research, whenever every one we have is training at all, and the ore for
  # the next is kept until it is there. Among five house bots with five or six Barracks each and
  # 100 to 130 Soldiers trained, we had three until tick 273 and five in all, and seven towers,
  # six depots, two Tech Labs and a base: 67 fighters.
  defp more_barracks({cmds, %{barracks_order: nil} = mem, ore} = acc, v, terrain, catch_up?) do
    barracks = View.buildings_of(v, "Barracks")
    {done, going_up} = Enum.split_with(barracks, & &1["completed"])
    catch_up? = catch_up? and length(barracks) < @max_barracks
    busy? = Enum.all?(done, &(length(&1["production"] || []) >= if(catch_up?, do: 1, else: 2)))
    cost = @costs["Barracks"]
    # One going up at a time, and one more for every `@barracks_bank` ore in the bank: with seven
    # of them full and 2,300 to 3,800 banked for 75 ticks, each new one waited for the last to finish.
    at_once = 1 + div(v.ore, @barracks_bank)

    with true <- done != [] and busy? and length(going_up) < at_once and length(barracks) < @max_barracks,
         true <- ore >= cost and v.ore >= cost + @worker_reserve,
         {_, _} = site <- site(terrain, v, :base) || Enum.find_value(View.base_ccs(v), &site(terrain, v, {:outpost, &1})),
         [_ | _] = free <- free_workers(v, mem) do
      builders = closest_first(free, site) |> Enum.take(usual_builders(v))
      order = %{type: "Barracks", builder: hd(builders)["id"], at: v.tick, had: length(barracks), site: site}
      {[build_cmd(builders, "Barracks", site) | cmds], %{mem | barracks_order: order}, ore - cost}
    else
      # Catching up, the ore for the next one isn't spent on anything else meanwhile.
      _ -> if catch_up? and done != [] and busy? and going_up == [], do: {cmds, mem, max(ore - cost, 0)}, else: acc
    end
  end

  # One on its way already: its ore stays set aside until it has broken ground.
  defp more_barracks({cmds, mem, ore}, _v, _terrain, _catch_up?), do: {cmds, mem, ore - @costs["Barracks"]}

  # The extra Barracks on its way, kept or forgotten like any pending building (`still_pending/2`);
  # one that didn't come is a strike against its site.
  defp settle_barracks(%{barracks_order: nil} = memory, _v), do: memory

  defp settle_barracks(%{barracks_order: order} = memory, v) do
    case still_pending(order, v) do
      nil -> if count(v, "Barracks") > order.had, do: %{memory | barracks_order: nil}, else: strike(%{memory | barracks_order: nil}, v, order.site)
      kept -> %{memory | barracks_order: kept}
    end
  end

  # Finished or not: a site under construction counts.
  defp count(v, type), do: length(View.buildings_of(v, type))

  defp prerequisites?(v, type) when type in @needs_barracks,
    do: Enum.any?(View.buildings_of(v, "Barracks"), & &1["completed"])

  defp prerequisites?(v, "SiegeWorkshop"),
    do: "SiegeEngineering" in v.upgrades and Enum.any?(View.buildings_of(v, "TechLab"), & &1["completed"])

  defp prerequisites?(_v, _type), do: true

  ## Spending what is left

  # Down to a few workers: workers come before anything else, out of the reserve too.
  defp rebuild_workers(acc, v, reserve) do
    if length(View.units_of(v, "Worker")) < @rebuild_workers and target_workers(v) > 0,
      do: with_reserve(acc, reserve, &train_workers(&1, v)),
      else: acc
  end

  # `spend` may use the reserve too; whatever of it is left stays back afterwards.
  defp with_reserve({cmds, mem, ore}, reserve, spend) do
    {cmds, mem, ore} = spend.({cmds, mem, ore + reserve})
    {cmds, mem, ore - reserve}
  end

  # From the main Command Center and every base one (`View.base?/2`), one each a tick, while we
  # are short of workers counting everything queued: two or three train at once.
  defp train_workers(acc, %View{cc: nil}), do: acc

  defp train_workers(acc, v) do
    trainers = for b <- View.buildings_of(v, "CommandCenter"), b["completed"], b["id"] == v.cc["id"] or View.base?(v, b), do: b
    queued = Enum.sum_by(trainers, &length(&1["production"] || []))
    short = target_workers(v) - length(View.units_of(v, "Worker")) - queued

    {acc, _short} =
      Enum.reduce(trainers, {acc, short}, fn cc, {{cmds, mem, ore} = acc, short} ->
        if short > 0 and length(cc["production"] || []) < 2 and ore >= @costs["Worker"] do
          cmd = %{"type" => "Produce", "buildingId" => cc["id"], "unitType" => "Worker"}
          {{[cmd | cmds], mem, ore - @costs["Worker"]}, short - 1}
        else
          {acc, short}
        end
      end)

    acc
  end

  # Regrouping: the backup Command Center trains its own `@backup_workers` workers (the ones within
  # 10 of it, counting those queued), who mine by it in secret. Nobody else is sent there.
  defp train_backup_workers({cmds, %{regroup: %{}} = mem, ore} = acc, v) do
    with %{} = backup <- backup_cc(v),
         queued = length(backup["production"]),
         near = Enum.count(View.units_of(v, "Worker"), &(View.dist(View.pos(&1), View.pos(backup)) <= 10)),
         true <- near + queued < @backup_workers,
         true <- ore >= @costs["Worker"] do
      cmd = %{"type" => "Produce", "buildingId" => backup["id"], "unitType" => "Worker"}
      {[cmd | cmds], mem, ore - @costs["Worker"]}
    else
      _ -> acc
    end
  end

  defp train_backup_workers(acc, _v), do: acc

  defp research({cmds, mem, ore} = acc, v) do
    case next_research(v, @research, cmds) do
      {lab, upgrade, cost} when ore >= cost -> {[research_cmd(lab, upgrade) | cmds], mem, ore - cost}
      _ -> acc
    end
  end

  # The research our fighters fight with (`@research_first`: Harvesting1, then every Weapons and
  # Armor) comes ahead of every building, base, worker and fighter, whenever a Tech Lab is free,
  # and its ore is kept until it is there. One on one, a house bot had Weapons2 and Armor2 at ticks
  # 385 and 391 and we at 441 and 431, behind two Command Centers and ten towers: 15 of its
  # Soldiers killed 22 of ours and 12 workers at our base for 9, on an estimate of +0.5.
  defp research_first({cmds, mem, ore} = acc, v) do
    case next_research(v, @research_first, cmds) do
      {lab, upgrade, cost} when ore >= cost -> {[research_cmd(lab, upgrade) | cmds], mem, ore - cost}
      {_lab, _upgrade, cost} -> {cmds, mem, ore - cost}
      nil -> acc
    end
  end

  # A free Tech Lab, the first of `list` we may start in it and what it costs, or nil.
  defp next_research(v, list, cmds) do
    # What this tick has started already (`research_first/2` runs ahead of `research/2`).
    started = for %{"type" => "Research"} = c <- cmds, do: {c["buildingId"], c["upgrade"]}
    {labs, upgrades} = Enum.unzip(started)
    lab = Enum.find(View.buildings_of(v, "TechLab"), &(&1["completed"] and &1["research"] == nil and &1["id"] not in labs))

    upgrade =
      Enum.find(list, fn u ->
        needs = @research_needs[u]

        u not in v.upgrades and u not in v.researching and u not in upgrades and (needs == nil or needs in v.upgrades) and
          (u != "SiegeEngineering" or siege_time?(v))
      end)

    if lab && upgrade, do: {lab, upgrade, @costs[upgrade]}
  end

  defp research_cmd(lab, upgrade), do: %{"type" => "Research", "buildingId" => lab["id"], "upgrade" => upgrade}

  # `@scouts` scouts while anyone is left to watch, counting ones being trained. From
  # the first free Barracks, one a tick.
  defp train_scout({cmds, mem, ore} = acc, v) do
    barracks = Enum.filter(View.buildings_of(v, "Barracks"), & &1["completed"])
    queued = for b <- barracks, p <- b["production"], p["unitType"] == "Scout", do: p
    free = Enum.find(barracks, &(length(&1["production"]) < 2))

    wanted = if Roles.neighbors(v) == [], do: 0, else: @scouts

    if length(View.units_of(v, "Scout")) + length(queued) < wanted and free != nil and ore >= @costs["Scout"] do
      cmd = %{"type" => "Produce", "buildingId" => free["id"], "unitType" => "Scout"}
      {[cmd | cmds], mem, ore - @costs["Scout"]}
    else
      acc
    end
  end

  # Once it is siege time, keep `@trebuchets` (counting ones being trained) from a finished SiegeWorkshop. Short of
  # the ore, set it aside like a building's, so soldiers don't spend it tick after tick and a
  # Trebuchet never comes. (The army floor trains first, so the base is never left bare for it.)
  defp train_siege({cmds, mem, ore} = acc, v) do
    workshops = Enum.filter(View.buildings_of(v, "SiegeWorkshop"), & &1["completed"])
    queued = for w <- workshops, p <- w["production"], p["unitType"] == "Trebuchet", do: p
    free = Enum.find(workshops, &(length(&1["production"]) < 2))
    cost = @costs["Trebuchet"]
    wanted = if siege_time?(v), do: trebuchets_wanted(v), else: 0

    cond do
      free == nil or length(View.units_of(v, "Trebuchet")) + length(queued) >= wanted ->
        acc

      ore >= cost ->
        cmd = %{"type" => "Produce", "buildingId" => free["id"], "unitType" => "Trebuchet"}
        {[cmd | cmds], mem, ore - cost}

      true ->
        {cmds, mem, ore - cost}
    end
  end

  # `@trebuchets`, and more for the opponent with the most towers we know of (`@towers_per_trebuchet`).
  defp trebuchets_wanted(v) do
    most = v |> Roles.enemy_towers() |> Enum.frequencies_by(& &1["owner"]) |> Map.values() |> Enum.max(fn -> 0 end)
    most |> Kernel.+(@towers_per_trebuchet - 1) |> div(@towers_per_trebuchet) |> max(@trebuchets) |> min(@max_trebuchets)
  end

  # Every finished Barracks trains non-stop: two soldiers for each archer.
  # (`terrain` nil: below the army floor, where nothing is saved for.)
  defp train_army(acc, v, terrain) do
    # Soldiers only. For the same ore, on the game's own engine, 30 Soldiers beat 20 Soldiers and
    # 8 Archers five times in five with 12 left (and 60 beat 40 and 16), kiting or not: Soldiers
    # are the faster, an Archer has 60 HP for 125 ore to a Soldier's 110 for 100, and its range is
    # worth three or four ticks of shots before they are on it. (It was one Archer to two Soldiers.)
    kind = "Soldier"

    # Rich: fill the queues (the game takes five) so the ore turns into units, not waste. Saving
    # for a base (`saving_for_base?/3`): one in each queue, which trains just as fast.
    queue =
      cond do
        terrain != nil and saving_for_base?(acc, v, terrain) -> 1
        rich?(v) -> 5
        true -> 2
      end

    Enum.reduce(View.buildings_of(v, "Barracks"), acc, fn b, {cmds, mem, ore} = acc ->
      if b["completed"] and length(b["production"]) < queue and ore >= @costs[kind] do
        cmd = %{"type" => "Produce", "buildingId" => b["id"], "unitType" => kind}
        {[cmd | cmds], mem, ore - @costs[kind]}
      else
        acc
      end
    end)
  end

  ## Sites

  @doc """
  Where to put a building, or nil if there is no room:

  - `:base`: 3–6 tiles from the Command Center, never on the ore side (between it and its ore, or
    within 3 of ore), then behind it (away from our neighbors)
  - `{:outpost, pos}`: 2–4 tiles from that outpost, toward the middle of the map
  - `:front`: a Guard Tower 3–4 tiles from the Command Center (so it covers the base), toward the
    nearest neighbor no tower faces yet: towers spread over the ways in
  - `:ore`: next to the ore deposit farthest from any drop-off (Command Center or Resource Depot),
    so its miners walk less. Nil if every deposit already has a drop-off close by.
  - `:expansion`: next to the ore with the shortest trip from a drop-off of those too far to mine
    (where idle workers go next). Nil if there is none in sight.

  Depots (`:ore`, `:expansion`) only go by ore on our side, closer to our Command Center than to
  any enemy's start, and not within 4 tiles of a spot in `avoid` (where we lost a building).
  """
  def site(terrain, view, where, avoid \\ [])

  def site(terrain, %View{cc: cc} = v, :base, _avoid) do
    home = View.pos(cc)
    threats = threat_points(v)
    from_threat = fn pos -> threats |> Enum.map(&dist2(&1, pos)) |> Enum.min() end

    ore_from = fn pos -> v.deposits |> Enum.map(&View.dist(View.pos(&1), pos)) |> Enum.min(fn -> 99 end) end
    home_ore = ore_from.(home)

    best_site(terrain, v, home, 3..6, fn tile, d ->
      near_ore = ore_from.(tile)
      # Never on the ore side: not between the Command Center and its ore (closer to the ore than
      # the Command Center is) nor within 3 of it. That side is the miners' path, and where the
      # depot goes, between the Command Center and the ore; a Barracks there pushed the depot
      # behind the ore. Then behind the Command Center (farther from the nearest neighbor than it
      # is); then close in; then as far from them as can be.
      ore_side = if near_ore <= 3 or near_ore < home_ore, do: 1, else: 0
      behind = if from_threat.(tile) > from_threat.(home), do: 0, else: 1
      {ore_side, behind, d, -from_threat.(tile)}
    end)
  end

  # A tower on the square around the whole base: 5–6 tiles from the Command Center, at least 5
  # from our other towers there if it can (their 5-tile reaches meet with no gap), the side facing
  # our neighbors first.
  def site(terrain, %View{cc: cc} = v, :square, _avoid) do
    home = View.pos(cc)
    threats = threat_points(v)
    towers = for t <- View.buildings_of(v, "GuardTower"), View.dist(View.pos(t), home) <= 9, do: View.pos(t)

    best_site(terrain, v, home, 5..6, fn tile, _d ->
      spread = towers |> Enum.map(&View.dist(&1, tile)) |> Enum.min(fn -> 99 end) |> min(5)
      {-spread, threats |> Enum.map(&dist2(&1, tile)) |> Enum.min()}
    end)
  end

  # The backup Command Center, hidden away from our base and never toward the middle of the map
  # (everyone crosses it):
  #   1. in a free corner of the map (no base starts within `@corner_free` of it; on a ring map
  #      none do, and in a 2–4 player game the unused ones are free), the one nearest us, ours
  #      (nearer us than any enemy start) if there is one: the farthest a spot can be from the
  #      middle, and nobody's way anywhere;
  #   2. else along our edge: no nearer the middle than our base (`@edge_slack` tiles), as far from
  #      the enemy as can be;
  # at least `@backup_near` tiles from our base, not by ore, an enemy building we know of, or the
  # very edge. Every other tile is enough, and keeps this quick on a big map.
  def site(terrain, %View{cc: cc} = v, :hideout, _avoid) do
    rows = List.to_tuple(terrain)
    home = View.pos(cc)
    middle = center(v)
    starts = [home | v.enemy_starts]
    enemy = Enum.map(v.enemy_buildings ++ v.remembered, &View.pos/1)
    taken = MapSet.new(Enum.map(v.my_buildings ++ v.enemy_buildings ++ v.deposits, &View.pos/1))
    margin = 3

    open? = fn {x, y} ->
      y in 0..(tuple_size(rows) - 1)//1 and x in 0..(byte_size(elem(rows, y)) - 1)//1 and
        :binary.at(elem(rows, y), x) == ?.
    end

    ok? = fn {x, y} = tile, near ->
      x >= margin and y >= margin and x < v.map_width - margin and y < v.map_height - margin and open?.(tile) and
        not Enum.any?(for(dx <- -1..1, dy <- -1..1, do: {x + dx, y + dy}), &MapSet.member?(taken, &1)) and
        not Enum.any?(enemy, &(View.dist(&1, tile) <= 8)) and
        not Enum.any?(v.deposits, &(View.dist(View.pos(&1), tile) <= 4)) and
        not Enum.any?(v.blocked, &(View.dist(&1, tile) <= @blocked_radius)) and
        View.dist(home, tile) >= near
    end

    ours? = fn tile -> Enum.all?(v.enemy_starts, &(dist2(home, tile) <= dist2(&1, tile))) end
    {w, h} = {v.map_width - 1, v.map_height - 1}

    corners =
      for corner <- [{0, 0}, {w, 0}, {0, h}, {w, h}],
          not Enum.any?(starts, &(View.dist(&1, corner) <= @corner_free)),
          do: corner

    in_corners =
      for {cx, cy} <- corners,
          x <- max(cx - @corner_zone, 0)..min(cx + @corner_zone, w)//2,
          y <- max(cy - @corner_zone, 0)..min(cy + @corner_zone, h)//2,
          ok?.({x, y}, @backup_near),
          do: {x, y}

    case in_corners do
      [_ | _] ->
        Enum.min_by(in_corners, fn tile -> {if(ours?.(tile), do: 0, else: 1), View.dist(home, tile), tile} end)

      [] ->
        # On a crowded map our side may have no room that far out: then nearer.
        along_edge = fn near ->
          for x <- margin..(w - margin)//3,
              y <- margin..(h - margin)//3,
              ok?.({x, y}, near),
              View.dist({x, y}, middle) >= View.dist(home, middle) - @edge_slack,
              ours?.({x, y}),
              View.dist(home, {x, y}) <= @backup_to,
              do: {x, y}
        end

        along_edge =
          case along_edge.(@backup_near) do
            [] -> along_edge.(6)
            found -> found
          end

        Enum.max_by(along_edge, fn tile -> {v.enemy_starts |> Enum.map(&dist2(&1, tile)) |> Enum.min(fn -> 0 end), tile} end, fn ->
          nil
        end)
    end
  end

  # By an outpost, on the side facing the middle of the map, like `:front`.
  def site(terrain, %View{} = v, {:outpost, {ox, oy}}, _avoid) do
    {mx, my} = center(v)
    best_site(terrain, v, {ox, oy}, 2..4, fn {x, y}, _d -> (x - mx) ** 2 + (y - my) ** 2 end)
  end

  def site(terrain, %View{cc: cc} = v, :front, _avoid) do
    {fx, fy} = front(v)
    towers = Enum.map(View.buildings_of(v, "GuardTower"), &View.pos/1)

    # Not right next to another tower, then as close to that neighbor as the ring allows.
    # Straight-line distance: with the game's distance, a whole row of tiles is equally far from
    # a point straight ahead, and the tie went to the map edge.
    best_site(terrain, v, View.pos(cc), @tower_ring, fn {x, y} = tile, _d ->
      {Enum.count(towers, &(View.dist(&1, tile) <= 2)), (x - fx) ** 2 + (y - fy) ** 2}
    end)
  end

  def site(terrain, %View{cc: cc} = v, :ore, avoid) do
    drop_offs = Enum.map([cc | View.buildings_of(v, "ResourceDepot")], &View.pos/1)
    from_drop_off = fn d -> drop_offs |> Enum.map(&View.dist(&1, View.pos(d))) |> Enum.min() end

    target =
      v.deposits
      |> Enum.filter(&(View.dist(View.pos(&1), View.pos(cc)) <= 15 and from_drop_off.(&1) >= 4))
      |> Enum.filter(&safe_ore?(v, &1, avoid))
      |> Enum.max_by(from_drop_off, fn -> nil end)

    if target, do: by_field(terrain, v, target)
  end

  def site(terrain, %View{cc: cc} = v, :expansion, avoid) do
    near = View.near_deposits(v)

    # The shortest trip from a drop-off, the way an idle worker picks its ore, so the miners and
    # the depot end up at the same field.
    # On our side first; with none there, ore clear of every enemy base (`View.claimable?/2`).
    target =
      v.deposits
      |> Enum.reject(&(&1 in near))
      |> Enum.filter(&(free_ore?(v, &1, avoid) and field_ore(v, &1) >= @expansion_ore))
      |> Enum.min_by(&{not View.ours?(v, View.pos(&1)), View.trip(v, &1), View.dist(View.pos(&1), View.pos(cc)), &1["id"]}, fn -> nil end)

    if target, do: by_field(terrain, v, target)
  end

  # A depot site right by `target` (`@depot_walk`), placed like `by_field/3`; nil when there is no
  # open tile that close. Never a site farther out: its miners would still walk, and the field
  # would keep asking for another depot.
  defp right_by(terrain, v, target) do
    case by_field(terrain, v, target) do
      {_, _} = tile -> if View.dist(tile, View.pos(target)) <= @depot_walk, do: tile
      _ -> nil
    end
  end

  # Ore worth a depot: on our side (closer to our Command Center than to any enemy's start, so
  # never a contested deposit between two players), not where we just lost a building, and not in
  # reach of an enemy tower.
  defp safe_ore?(%View{} = v, deposit, avoid) do
    pos = View.pos(deposit)
    View.ours?(v, pos) and not Enum.any?(avoid, &(View.dist(&1, pos) <= 4)) and not Roles.under_tower?(v, pos)
  end

  # Ore a depot may go by when home runs short: like `safe_ore?/3`, but off our side too, as long
  # as it is clear of every enemy base.
  defp free_ore?(%View{} = v, deposit, avoid) do
    pos = View.pos(deposit)
    View.claimable?(v, pos) and not Enum.any?(avoid, &(View.dist(&1, pos) <= 4)) and not Roles.under_tower?(v, pos)
  end

  # Towers shoot buildings too, once no unit is in reach: a Guard Tower of ours in reach of the
  # Command Center we spare (`v.spared`) would end the match on its own. Not there.
  defp clear_of_spared?(%View{spared: nil}, _type, _site), do: true
  defp clear_of_spared?(_v, type, _site) when type != "GuardTower", do: true
  defp clear_of_spared?(%View{spared: spared}, _type, site), do: View.dist(site, spared) > @tower_reach + 1

  # By the field around `target`, two tiles from as many of its deposits as possible: a worker
  # on the tile between depot and deposit mines and banks without a step (units stack, so they
  # all can). Then close to the whole field; on our side of it when that's a tie.
  defp by_field(terrain, %View{cc: cc} = v, target) do
    field = Enum.filter(v.deposits, &(View.dist(View.pos(&1), View.pos(target)) <= 4))

    best_site(terrain, v, View.pos(target), 2..3, fn tile, _d ->
      {-Enum.count(field, &(View.dist(View.pos(&1), tile) == 2)), Enum.sum_by(field, &View.dist(View.pos(&1), tile)),
       View.dist(tile, View.pos(cc))}
    end)
  end

  # The open tile `ring` tiles from `{cx, cy}` with the lowest `score.(tile, distance)`: on the map, open ground, not on or
  # next to the ore, and not touching another
  # building (so nothing gets walled in).
  defp best_site(terrain, %View{} = v, {cx, cy}, ring, score) do
    height = length(terrain)
    width = if height > 0, do: String.length(hd(terrain)), else: 0
    buildings = Enum.map(v.my_buildings ++ v.enemy_buildings, &View.pos/1)
    ore = Enum.map(v.deposits, &View.pos/1)

    candidates =
      for y <- (cy - ring.last)..(cy + ring.last),
          x <- (cx - ring.last)..(cx + ring.last),
          d = View.dist({x, y}, {cx, cy}),
          d in ring,
          x in 0..(width - 1)//1 and y in 0..(height - 1)//1,
          String.at(Enum.at(terrain, y), x) == ".",
          not Enum.any?(buildings, &(View.dist(&1, {x, y}) <= 1)),
          not Enum.any?(ore, &(View.dist(&1, {x, y}) <= 1)),
          not Enum.any?(v.blocked, &(View.dist(&1, {x, y}) <= @blocked_radius)),
          # Towers shoot buildings too: nothing goes up in reach of an enemy one.
          not Roles.under_tower?(v, {x, y}) do
        {score.({x, y}, d), {x, y}}
      end

    case Enum.min_by(candidates, &elem(&1, 0), fn -> nil end) do
      nil -> nil
      {_score, site} -> site
    end
  end
end
