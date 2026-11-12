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

  alias Swarm.{Roles, View}

  @target_workers 20
  # A big game needs a bigger economy to out-grow everyone: this many workers there.
  @big_target_workers 30
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
  @serum_margin 1.25
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
  # point, unless we looked at that player in the last `@look_fresh` ticks. It goes to `@look_from`
  # tiles short of the target (its vision is 8); the look is done once a scout is within
  # `@look_sight` of that spot. The launch waits at most `@look_timeout` ticks for it.
  @look_at 5
  @look_fresh 60
  @look_from 7
  @look_sight 3
  @look_timeout 40
  # How far our units see, for forgetting enemies we should see and don't (one less, as they move).
  @vision %{"Scout" => 8, "Archer" => 6, "Trebuchet" => 7, "GuardTower" => 7}
  @default_vision 6
  @all_in_ticks 300
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
  @siege_camp_distance 9
  # It comes down this many ticks before the end, for its 400 and the win by elimination: the
  # army at the camp walks the 6 tiles and knocks its 1500 HP down in about ten.
  @spare_until 30
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

  # Built once the build order is done and only while rich, one at a time, in this order.
  @extras [
    {"Barracks", 3, :base},
    {"GuardTower", 3, :front},
    {"Barracks", 4, :base},
    {"GuardTower", 4, :front},
    {"GuardTower", 5, :front}
  ]

  # Siege is only for knocking down the enemy's towers with a wave: at home a Trebuchet (350 ore)
  # is a fifth as strong as the 3.5 Soldiers it costs, and can't hit anything close. So
  # SiegeEngineering, the SiegeWorkshop and the Trebuchets wait for this many fighters (and the
  # build order to be done), and then we keep `@trebuchets` of them, for the waves.
  @siege_after_fighters 25
  @trebuchets 2
  # Trebuchets needed at the rally point to go out with a wave.
  @siege_group 2
  # A wave with siege waits this far short of the target for it, at most `@siege_wait` ticks.
  @staging_distance 9
  @siege_wait 60

  # How far from the Command Center a tower goes: a tower hits 5 tiles out, so from here it covers
  # the Command Center, the ore line and the guards.
  @tower_ring 3..4

  # {building, how many we want, workers we need first, where it goes}, built one at a time.
  # The second Command Center is the backup: built far from every base (`:hideout`), so that losing
  # the main one doesn't eliminate us (a player is out only with no Command Center at all), which
  # would also wipe our survival score. Rebuilt if lost.
  # The backup Command Center comes last, once the rest is up and we have 10 fighters: early on
  # it is 400 ore while the first raids come, and with few players nobody is about to wipe us out.
  @build_order [
    {"Barracks", 1, 7, :base},
    {"ResourceDepot", 1, 9, :ore},
    {"GuardTower", 1, 11, :front},
    {"TechLab", 1, 13, :base},
    {"Barracks", 2, 15, :base},
    {"GuardTower", 2, 17, :front},
    {"CommandCenter", 2, 17, :hideout, 10}
  ]

  # In a big game: three Barracks early to mass-produce, a square of `@big_towers` towers around
  # the whole base (`:square`), and no first wave until it is up. The army comes first: an entry's
  # optional fifth number is the fighters we must have before it is built (the backup Command
  # Center at 10, the rest of the square at 15), so the ore goes into soldiers until then.
  @big_build_order [
                     {"Barracks", 1, 7, :base},
                     {"ResourceDepot", 1, 9, :ore},
                     {"GuardTower", 1, 10, :square},
                     {"Barracks", 2, 12, :base},
                     {"TechLab", 1, 13, :base},
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
                        {"Barracks", 1, 7, :base},
                        {"ResourceDepot", 1, 9, :ore},
                        {"GuardTower", 1, 10, :front},
                        {"GuardTower", 2, 11, :front},
                        {"Barracks", 2, 12, :base},
                        {"TechLab", 1, 13, :base},
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
  @short_for_ticks 30
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

  # Each tier 2 comes after its tier 1, and a TechLab researches one at a time.
  @research ["Harvesting1", "Weapons1", "Armor1", "SiegeEngineering", "Harvesting2", "Weapons2", "Armor2"]

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

  # The last opponent's last Command Center, left standing (`spare/3`): its id and where it is;
  # `goal`, where the wave goes (their nearest other building, else `camp`); `camp`, where the
  # army waits by it, out of its own reach; `siege_camp`, the same for Trebuchets.
  @type spare :: %{id: integer(), pos: pos(), goal: pos(), camp: pos(), siege_camp: pos()}

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
      # The last opponent's last Command Center we leave standing (its id, for logging it once),
      # and whether that was given up for this match (their army came back; see `spare/3`).
      spared: nil,
      spare_lifted: false
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

    v = %{v | regroup: memory.regroup && memory.regroup.pos, recent_enemies: recent_enemies(v, memory.enemies)}
    {View.with_known_ore(v, ore), %{memory | ore: ore}}
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

    surveyed = if memory.survey && current == nil, do: Enum.uniq([memory.survey.pos | surveyed]), else: surveyed
    left = Enum.reject(spots, &(&1 in surveyed))
    scout = surveyor(v)

    {current, notes} =
      cond do
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
    spots = Enum.reject(Roles.help_wanted(v), &Roles.covered?(v, &1))

    resting? = memory.help_off_at != nil and v.tick - memory.help_off_at < @help_rest

    case memory.help do
      nil when resting? ->
        {nil, memory, []}

      nil ->
        case spots |> Enum.filter(&may_help?(v, memory, s, &1)) |> Enum.min_by(&{View.dist(&1, s.rally || &1), &1}, fn -> nil end) do
          nil -> {nil, memory, []}
          spot -> {spot, %{memory | help: %{pos: spot, clear_since: nil}}, [{:help, "home goes to help at #{fmt(spot)}"}]}
        end

      %{pos: pos} = help ->
        near = Enum.filter(spots, &(View.dist(&1, pos) <= @help_follow))
        # It follows the fight only to where home can still take what is there: following onto
        # the middle of the pack had it called off the next tick, and committed again at its edge.
        takeable = Enum.filter(near, &Roles.can_take?(v, s.wave, &1))
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
            {pos, %{memory | help: %{pos: pos, clear_since: clear_since}}, []}
        end
    end
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

  # Spots to look at for ore once home runs short, anywhere on our side of the map (all of it with
  # the last opponent spared, see `plan/3`): every eliminated player's start, and a grid
  # `@far_grid` tiles apart, on open ground (the nearest open tile within 3).
  defp far_spots(%View{} = v, terrain) do
    rows = List.to_tuple(terrain)

    open? = fn {x, y} ->
      y in 0..(tuple_size(rows) - 1)//1 and x in 0..(byte_size(elem(rows, y)) - 1)//1 and :binary.at(elem(rows, y), x) == ?.
    end

    half = div(@far_grid, 2)
    grid = for x <- half..(v.map_width - 1)//@far_grid, y <- half..(v.map_height - 1)//@far_grid, do: {x, y}

    for {x, y} <- v.fallen_starts ++ grid,
        View.ours?(v, {x, y}),
        spot = Enum.find(for(d <- 0..3, dx <- -d..d, dy <- -d..d, do: {x + dx, y + dy}), open?),
        spot != nil,
        uniq: true,
        do: spot
  end

  @spec plan(View.t(), map(), [String.t()]) :: {strategy(), [map()], map()}
  def plan(%View{} = v, memory, terrain) do
    # Memory from an older version may have other keys: keep only the ones we know.
    memory = new_memory() |> Map.merge(memory || %{}) |> Map.take(Map.keys(new_memory()))
    memory = %{memory | raid: raid(memory, v), enemies: remember_enemies(memory.enemies, v)}
    {strategy, memory} = strategy(v, memory)
    # With the last opponent down to the Command Center we spare, their side of the map is ours
    # too: its ore is looked for and taken like ours. Their start counted as enemy ground left 30
    # workers idle for the last 600 ticks of a game, with 20,000 ore on the map.
    v = if Map.get(strategy, :spare), do: %{v | enemy_starts: []}, else: v
    {survey, memory, surveyed} = survey(v, memory, terrain)
    {regroup, memory, regrouped} = regroup(v, memory)
    {help, memory, helped} = help(v, memory, strategy)
    strategy = %{strategy | survey: survey, regroup: regroup, help: help, why: strategy.why ++ surveyed ++ regrouped ++ helped}
    memory = %{memory | pending: still_pending(memory.pending, v), ore_short_since: short_since(memory, v)}
    memory = remember_losses(memory, v)

    # Ore for a couple of workers stays back from everything else once the army is being trained
    # (a Barracks is up, or past the opening: the Barracks may be gone): with every worker dead and
    # nothing banked, the economy never starts again. Not in the opening, where every bit of ore
    # goes into the first buildings.
    opening? = v.tick < @opening_ticks and not Enum.any?(View.buildings_of(v, "Barracks"), & &1["completed"])
    reserve = if opening?, do: 0, else: min(v.ore, @worker_reserve)
    # While the main base is raided or overrun, workers trained there only die: the reserve waits
    # for the backup's own workers (first claim on it) or for the raid to be gone.
    home_reserve = if Roles.threat(v) != nil or memory.regroup, do: 0, else: reserve

    {commands, memory, _ore} =
      {[], memory, v.ore - reserve}
      |> with_reserve(reserve, &train_backup_workers(&1, v))
      |> rebuild_workers(v, home_reserve)
      |> finish_sites(v)
      |> army_floor(v)
      |> build(v, terrain)
      |> with_reserve(home_reserve, &train_workers(&1, v))
      |> research(v)
      |> train_scout(v)
      |> train_siege(v)
      |> train_army(v)

    {strategy, Enum.reverse(commands), memory}
  end

  # No base left: everyone attacks.
  defp strategy(%View{cc: nil} = v, memory) do
    target = target_of(v, opponent(v, memory))
    {%{mode: :attack, target: target, rally: nil, post: nil, threat: nil, wave: nil, why: [], hold: nil, look: nil, serum: nil, raze: nil, check: %{},
       fall_back: false, spare: nil, survey: nil, regroup: nil, peek: nil, help: nil}, memory}
  end

  defp strategy(%View{} = v, memory) do
    rally = rally(v)
    threat = Roles.threat(v)
    # Any base under attack, outposts included, or our workers out in the field.
    attacked? = threat != nil or Roles.help_wanted(v) != []
    owner = opponent(v, memory)
    target = target_of(v, owner)
    # Called home to defend this tick (all in, nothing comes home).
    home_recall? = memory.wave != nil and not all_in?(v) and Roles.recall(v, memory.wave) != nil
    recalled_at = if home_recall?, do: v.tick, else: memory.recalled_at
    # Called home for an army near home: no new wave for `@calm_ticks` either, counterattack or
    # not: the army is still about, and a wave leaving into it was called straight back.
    army_recall? = memory.wave != nil and not all_in?(v) and army_near_home(v, memory, memory.wave) != nil
    memory = if army_recall?, do: %{memory | army_recalled_at: v.tick}, else: memory
    calm? = recalled_at == nil or v.tick - recalled_at >= @calm_ticks
    {look, looked} = look(memory, v, rally, owner, target)
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
        _ -> target
      end

    check = if wave && Map.get(wave, :kind) == :sortie, do: nil, else: memory.check

    # The last opponent's last Command Center stays up (`spare/3`); the wave goes for the rest.
    # The wave out at the start of the tick counts too: one called back this tick for their army.
    {spare, spare_why, memory} = spare(v, memory, wave || memory_wave)
    target = if spare, do: spare.goal, else: target
    why = why ++ spare_why

    strike_back_at =
      if memory_wave && Map.get(memory_wave, :kind) == :strike && wave == nil, do: v.tick, else: memory.strike_back_at

    # Home falls back to the towers when the raiders outside their reach are too strong for it.
    # It holds `@fall_back_hold` ticks past the last reason to: raiders stepping in and out of
    # sight would flip it every tick, and workers and defenders with it.
    fall_back_at = if Roles.fall_back?(v, wave), do: v.tick, else: memory.fall_back_at
    fall_back = fall_back_at != nil and v.tick - fall_back_at < @fall_back_hold
    why = why ++ fall_back_note(v, wave, fall_back, memory.fall_back)

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
      raze: raze(v),
      check: if(check && check.found == nil, do: check.checkers, else: %{}),
      fall_back: fall_back,
      spare: spare,
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
         fall_back_at: fall_back_at
     }}
  end

  # A line for the decision log when home starts or stops falling back.
  defp fall_back_note(v, wave, true, false) do
    exposed = Roles.exposed_raiders(v)
    {theirs, ours} = {Roles.strength(exposed), Roles.all_home_strength(v, wave, exposed)}

    [{:fall_back,
      "#{length(exposed)} raiders out of our towers' reach, strength #{round(theirs)} vs #{round(ours)} at home: " <>
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
  defp look(memory, v, rally, owner, target) do
    {look, why} = settle_look(memory.look, v, memory)

    want? =
      cond do
        owner == nil or target == nil or v.cc == nil -> false
        looking?(look, owner) or fresh?(look, owner, v) -> false
        # With a wave out, a scout works in front of it instead (see `Swarm.UnitBrain`).
        memory.wave != nil -> false
        true -> length(elem(launch_group(v, memory, rally, false), 1)) >= @look_at
      end

    if want? do
      spot = toward(target, View.pos(v.cc), @look_from)
      {%{owner: owner, pos: spot, at: v.tick, done: nil}, why ++ [{:scout_sent, "scout looking at player #{owner} by #{fmt(spot)}"}]}
    else
      {look, why}
    end
  end

  defp settle_look(%{done: nil} = look, v, memory) do
    there? = Enum.any?(View.units_of(v, "Scout"), &(View.dist(View.pos(&1), look.pos) <= @look_sight))

    cond do
      there? ->
        seen = memory.enemies |> Map.values() |> Enum.filter(&(&1["owner"] == look.owner))
        why = "scouted player #{look.owner}: #{length(seen)} fighters, strength #{round(Roles.strength(seen))}"
        {%{look | done: v.tick}, [{:scouted, why}]}

      View.units_of(v, "Scout") == [] or v.tick - look.at >= @look_timeout ->
        why = "no look at player #{look.owner} (no scout got there in #{v.tick - look.at} ticks): going on what we know"
        {%{look | done: v.tick}, [{:scouted, why}]}

      true ->
        {look, []}
    end
  end

  defp settle_look(look, _v, _memory), do: {look, []}

  defp looking?(look, owner), do: look != nil and look.owner == owner and look.done == nil
  defp fresh?(look, owner, v), do: look != nil and look.owner == owner and look.done != nil and v.tick - look.done <= @look_fresh

  # `n` tiles from `from` toward `to` (or `to` itself, if it is closer).
  defp toward({fx, fy} = from, {tx, ty} = to, n) do
    d = View.dist(from, to)
    if d <= n, do: to, else: {fx + div((tx - fx) * n, d), fy + div((ty - fy) * n, d)}
  end

  defp fmt({x, y}), do: "(#{x},#{y})"

  # Enemy fighters as last seen. Ones we killed, haven't seen in a while, or should see where we
  # last saw them and don't (they died out of our sight, or moved on) are dropped.
  defp remember_enemies(enemies, %View{} = v) do
    killed = for e <- v.events, e["kind"] == "UnitKilled", do: e["entityId"]

    seen =
      for u <- v.enemy_units, u["type"] != "Worker", into: %{} do
        {u["id"], u |> Map.take(["id", "owner", "type", "hp", "x", "y"]) |> Map.put("seen", v.tick)}
      end

    eyes =
      for(u <- v.my_units, do: {View.pos(u), Map.get(@vision, u["type"], @default_vision) - 1}) ++
        for b <- v.my_buildings, b["completed"], do: {View.pos(b), Map.get(@vision, b["type"], @default_vision) - 1}

    in_sight? = fn e -> Enum.any?(eyes, fn {pos, r} -> View.dist(pos, View.pos(e)) <= r end) end

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
      memory.wave -> keep_wave(v, memory, rally, target)
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

      facing = outmatched(v, alive, spot) ->
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

      facing = outmatched(v, alive, wave.tower_pos) ->
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
    members = v |> Roles.fighters() |> Enum.map(& &1["id"]) |> Enum.sort()

    case memory.wave do
      %{all_in: true} = wave ->
        {%{wave | members: members}, memory.next_wave, []}

      _ ->
        why =
          "behind on score (#{v.my_score} vs #{v.enemy_score}) with #{v.max_ticks - v.tick} ticks left: " <>
            "all #{length(members)} fighters attack"

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

      length(alive) < @recall_below ->
        {nil, memory.next_wave, [{:wave_recalled, "wave #{wave.id}: only #{length(alive)} left"}], nil}

      losses = bleeding(wave, alive) ->
        {nil, memory.next_wave, [{:wave_recalled, "wave #{wave.id}: #{losses}"}], nil}

      facing = outmatched(v, alive, target) ->
        {player, theirs} = facing
        why = "wave #{wave.id}: outmatched by player #{player}, strength #{round(Roles.strength(alive))} vs #{round(theirs)} nearby"
        {nil, memory.next_wave, [{:wave_recalled, why}], nil}

      true ->
        wave = %{wave | members: Enum.map(alive, & &1["id"])} |> peaked(alive)
        {wave, more, hold} = reinforce(v, wave, rally)
        {wave, next_wave, why} = release(v, wave, memory.next_wave)
        {wave, next_wave, more ++ why, hold}
    end
  end

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
  defp release(v, %{released: false} = wave, next_wave) do
    siege = Enum.filter(v.my_units, &(&1["type"] == "Trebuchet" and &1["id"] in wave.members))
    there? = Enum.all?(siege, &(View.dist(View.pos(&1), wave.staging) <= @staged_radius))

    if there? or v.tick - wave.at >= @siege_wait do
      why = "wave #{wave.id}: #{length(siege)} trebuchet(s) in place, going in"
      {%{wave | released: true}, next_wave, [{:wave_released, why}]}
    else
      {wave, next_wave, []}
    end
  end

  defp release(_v, wave, next_wave), do: {wave, next_wave, []}

  # The strongest single enemy player at the wave's front, as {player, strength}, if stronger than
  # the whole wave; else nil. Players are counted apart: two fighting each other near us don't add
  # up, and we may well come in on them.
  # The front: the members within `@wave_sight` of the one nearest the target (reinforcements
  # walking up behind are counted in the wave, not in where it is fighting).
  defp outmatched(v, alive, target) do
    case facing(v, alive, target) do
      {_player, theirs} = top when theirs > 0 -> if Roles.strength(alive) < theirs, do: top
      _ -> nil
    end
  end

  # The strongest single enemy player at the wave's front, as {player, strength}, or nil.
  defp facing(v, alive, target) do
    lead = if target, do: Enum.min_by(alive, &View.dist(View.pos(&1), target)), else: hd(alive)
    front = Enum.filter(alive, &(View.dist(View.pos(&1), View.pos(lead)) <= @wave_sight))
    n = length(front)
    center = {div(Enum.sum_by(front, & &1["x"]), n), div(Enum.sum_by(front, & &1["y"]), n)}
    near? = &(View.dist(View.pos(&1), center) <= @wave_sight)

    (Enum.filter(v.enemy_units, &(&1["type"] != "Worker" and near?.(&1))) ++
       Enum.filter(Roles.enemy_towers(v), near?))
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
  #     can meet it at home, not a coin flip. The serum doubles soldiers' speed too, so a far wave
  #     gets home twice as fast.
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

    raiders != [] and raid >= @serum_raid and overrun? and length(View.units_of(v, "Soldier")) >= @serum_soldiers
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

    siege = if length(siege) >= @siege_group, do: siege, else: []

    scouted? = memory.enemies != %{} or v.enemy_buildings != [] or v.remembered != []

    ours = Roles.strength(staged ++ siege)
    theirs = enemy_strength(v, memory, owner)

    early? = early_strike?(v, memory, owner, staged, ours, theirs)
    want = if early?, do: @early_min, else: wave_min(v, memory)

    ready? =
      if scouted?,
        do: length(staged) >= want and ours >= @margin * theirs,
        else: length(staged) >= max(@first_wave, want)

    leaving = %{members: Enum.map(staged ++ siege, & &1["id"])}
    home = Roles.recall(v, leaving)
    place = if from == rally, do: "the rally point", else: fmt(from)
    at_rally = "#{length(staged)} attackers at #{place} (#{length(attackers)} in all)"

    hold =
      cond do
        not calm? and not counter? ->
          "back from a recall for home, #{@calm_ticks - (v.tick - memory.recalled_at)} more ticks"

        memory.raid && Roles.raiders(v) == [] && v.tick - memory.raid.at < @raid_gone ->
          "a raid only just out of sight, #{@raid_gone - (v.tick - memory.raid.at)} more ticks"

        memory.came_home_at && v.tick - memory.came_home_at < @calm_ticks ->
          "the last wave took its player out and is coming home, #{@calm_ticks - (v.tick - memory.came_home_at)} more ticks"

        memory.check_next and not fresh?(memory.look, owner, v) ->
          "#{at_rally}, a look at player #{owner} first: the next one after taking one out"

        memory.army_recalled_at && v.tick - memory.army_recalled_at < @calm_ticks ->
          "back from a recall for an army near home, #{@calm_ticks - (v.tick - memory.army_recalled_at)} more ticks"

        not scouted? and not ready? ->
          "#{at_rally}, want #{max(@first_wave, want)} while nothing is scouted"

        length(staged) < want ->
          "#{at_rally}, want #{want}"

        (towers = if(early?, do: nil, else: towers_short(v, memory))) != nil ->
          "#{at_rally}, building the tower square first (#{towers} of #{@big_towers})"

        not counter? and looking?(memory.look, owner) ->
          "#{at_rally}, scout looking at player #{owner} (#{v.tick - memory.look.at} ticks)"

        not ready? ->
          "#{at_rally}, strength #{round(ours)} vs #{@margin} x #{round(theirs)} = #{round(@margin * theirs)} known of player #{owner}"

        (way = target && in_the_way(v, from, target)) && elem(way, 1) > ours ->
          {player, strength} = way
          "#{at_rally}, player #{player}'s army is in the way (#{round(strength)} vs our #{round(ours)})"

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
        at: v.tick
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
  The army we remember of player `owner` (all opponents if nil), plus their finished towers we
  know of. An enemy remembered without an owner counts against everyone.
  """
  def enemy_strength(%View{} = v, memory, owner \\ nil) do
    theirs? = &(owner == nil or &1["owner"] in [owner, nil])

    towers =
      (v.enemy_buildings ++ v.remembered)
      |> Enum.filter(&(&1["type"] == "GuardTower" and &1["completed"] != false and theirs?.(&1)))
      |> Enum.uniq_by(& &1["id"])

    army = memory.enemies |> Map.values() |> Enum.filter(theirs?)
    Roles.strength(army) + Roles.strength(towers)
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

        v
        |> Roles.neighbors()
        |> Enum.min_by(fn {start, slot} -> {Map.get(v.enemy_survival, slot, 0), View.dist(start, from)} end, fn -> nil end)
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

  # The last opponent's last Command Center is left standing: killing it ends the match, and with
  # it our score (economy is all the ore we ever mined, survival all we have alive). So the wave
  # takes everything else of theirs, then camps by it (`camp`, `@camp_distance` out: farther than an
  # Archer reaches, so nobody standing there hits it on their own) and kills whatever it makes.
  # Lifted for good (`memory.spare_lifted`) once a wave out is no longer `@margin` times what we
  # know of their army, the same test a wave leaves on: then it comes down after all. And in the
  # last `@spare_until` ticks it comes down anyway.
  # Returns {the spare or nil, what to log, memory}.
  defp spare(v, memory, wave) do
    case last_cc(v) do
      nil ->
        {nil, [], memory}

      _ when memory.spare_lifted ->
        {nil, [], memory}

      {owner, _cc} when v.tick >= v.max_ticks - @spare_until ->
        why = "#{v.max_ticks - v.tick} ticks left: player #{owner}'s last Command Center comes down"
        {nil, [{:spare_lifted, why}], %{memory | spare_lifted: true, spared: nil}}

      {owner, cc} ->
        alive = if wave, do: Enum.filter(v.my_units, &(&1["id"] in wave.members)), else: []
        {ours, theirs} = {Roles.strength(alive), enemy_strength(v, memory, owner)}

        if wave != nil and ours < @margin * theirs do
          why = "player #{owner}'s army is back (#{round(theirs)} vs our #{round(ours)} out): their last Command Center comes down"
          {nil, [{:spare_lifted, why}], %{memory | spare_lifted: true, spared: nil}}
        else
          spare = spare_spots(v, owner, cc)

          why =
            if memory.spared == cc["id"],
              do: [],
              else: [{:spare, "player #{owner}'s last Command Center at #{fmt(spare.pos)} stays up: we farm until the end"}]

          {spare, why, %{memory | spared: cc["id"]}}
        end
    end
  end

  # The only opponent left and their only Command Center, {owner, it}, when nothing they have
  # alive can be another one: their survival score (the ore value of everything they have alive)
  # less the Command Center, the units of theirs we see and their other buildings we know of
  # leaves less than a Command Center's worth unaccounted for.
  defp last_cc(%View{cc: cc, enemy_survival: survival} = v) when cc != nil and map_size(survival) == 1 do
    [{owner, worth}] = Map.to_list(survival)
    known = (v.enemy_buildings ++ v.remembered) |> Enum.filter(&(&1["owner"] == owner)) |> Enum.uniq_by(& &1["id"])
    value = &Enum.sum_by(&1, fn e -> Map.get(@costs, e["type"], 0) end)

    case Enum.filter(known, &(&1["type"] == "CommandCenter")) do
      [their_cc] ->
        units = value.(Enum.filter(v.enemy_units, &(&1["owner"] == owner)))
        others = value.(Enum.filter(known, &(&1["id"] != their_cc["id"] and &1["completed"] != false)))
        if worth - @costs["CommandCenter"] - units - others < @costs["CommandCenter"], do: {owner, their_cc}

      _ ->
        nil
    end
  end

  defp last_cc(_v), do: nil

  defp spare_spots(v, owner, cc) do
    pos = View.pos(cc)
    home = View.pos(v.cc)

    others =
      for b <- v.enemy_buildings ++ v.remembered, b["owner"] == owner, b["id"] != cc["id"], do: View.pos(b)

    camp = toward(pos, home, @camp_distance)
    goal = if others == [], do: camp, else: Enum.min_by(others, &{View.dist(&1, home), &1})
    %{id: cc["id"], pos: pos, goal: goal, camp: camp, siege_camp: toward(pos, home, @siege_camp_distance)}
  end

  # `@staging_distance` short of the target, on our side of it, kept on the map.
  defp staging(v, {tx, ty}, {rx, ry}) do
    {clamp(tx + @staging_distance * sign(rx - tx), v.map_width), clamp(ty + @staging_distance * sign(ry - ty), v.map_height)}
  end

  defp clamp(n, size), do: n |> max(0) |> min(size - 1)

  # Where guards stand: behind the Guard Tower closest to the enemy, else the rally point.
  defp post(v, rally, enemy) do
    case Enum.filter(View.buildings_of(v, "GuardTower"), & &1["completed"]) do
      [] ->
        rally

      towers ->
        {x, y} = towers |> Enum.map(&View.pos/1) |> Enum.min_by(&View.dist(&1, enemy))
        {cx, cy} = View.pos(v.cc)
        {x + sign(cx - x), y + sign(cy - y)}
    end
  end

  # Three tiles from the Command Center toward the middle of the map.
  defp rally(%View{cc: cc} = v) do
    {x, y} = View.pos(cc)
    {cx, cy} = center(v)
    {x + 3 * sign(cx - x), y + 3 * sign(cy - y)}
  end

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
  defp still_pending(nil, _v), do: nil

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

  # A site nobody is working on (its builder died or was called away) gets the closest free
  # worker. Its cost was paid when it was started, so this needs no ore.
  defp finish_sites({cmds, mem, ore}, v) do
    unfinished = Enum.reject(v.my_buildings, & &1["completed"])
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

  # Free workers go build it (see `builders/4`); we remember the first so we can tell if the order
  # fails. With no free worker, keep the ore aside and try again next tick.
  defp order({cmds, mem, ore}, v, type, site) do
    case free_workers(v, mem) do
      [] ->
        {cmds, mem, ore - @costs[type]}

      free ->
        builders = builders(v, free, type, site)
        pending = %{type: type, builder: hd(builders)["id"], at: v.tick, had: count(v, type)}
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

    case users do
      [] -> closest_first(free, site) |> Enum.take(usual_builders(v))
      users -> closest_first(users, site) |> Enum.take(@depot_builders)
    end
  end

  # The backup Command Center: 80 work, two builders.
  defp builders(_v, free, "CommandCenter", site), do: closest_first(free, site) |> Enum.take(2)

  defp builders(v, free, "Barracks", site) do
    n = if count(v, "Barracks") == 0, do: @first_barracks_builders, else: usual_builders(v)
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
    depot = if may_expand?(v), do: conquest_depot(v, terrain, mem) || remote_depot(v, terrain, mem) || expansion(v, terrain, mem)

    case depot do
      nil ->
        # In a big game a co-op's tower comes before the rest: outposts are where raiders go.
        if big?(v),
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

  defp target_workers(v), do: if(big?(v), do: @big_target_workers, else: @target_workers)

  # A new co-op away from home, in a big game only with an army to hold it.
  defp may_expand?(v), do: not big?(v) or length(Roles.fighters(v)) >= @expand_army

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
         false <- Enum.any?(avoid, &(View.dist(&1, View.pos(target)) <= 4)) do
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
    building_one? = Enum.any?(View.buildings_of(v, "ResourceDepot"), &(not &1["completed"]))
    short_long_enough? = mem.ore_short_since != nil and v.tick - mem.ore_short_since >= @short_for_ticks

    if short_long_enough? and not building_one?, do: site(terrain, v, :expansion, avoid(v, mem))
  end

  # Where we lost a building lately (`mem.lost`) and enemy fighters we know of are still near (within
  # `@lost_clear`): no new depot or building there yet. Once they are gone, we build again: a lost
  # depot by the only ore left otherwise has every worker walking to the Command Center for good.
  defp avoid(v, mem) do
    enemies = for {_id, e} <- mem.enemies, e["type"] not in ["Worker", "Scout"], do: View.pos(e)
    enemies = enemies ++ for(e <- v.enemy_units, e["type"] not in ["Worker", "Scout"], do: View.pos(e))

    for spot <- Map.keys(mem.lost), Enum.any?(enemies, &(View.dist(&1, spot) <= @lost_clear)), do: spot
  end

  # A building of ours that was there last tick and isn't now was destroyed: remember the spot.
  defp remember_losses(memory, v) do
    now = Map.new(v.my_buildings, &{&1["id"], View.pos(&1)})
    gone = memory.buildings |> Map.drop(Map.keys(now)) |> Map.values()

    lost =
      memory.lost
      |> Map.merge(Map.new(gone, &{&1, v.tick}))
      |> Map.reject(fn {_spot, at} -> v.tick - at > @avoid_lost_ticks end)

    %{memory | buildings: now, lost: lost, hp: Map.new(v.my_buildings, &{&1["id"], &1["hp"]})}
  end

  # Since when home has been short of ore (see `@low_home_ore`), or nil if it isn't.
  defp short_since(_memory, %View{cc: nil}), do: nil

  defp short_since(memory, v) do
    near = View.near_deposits(v)
    ore_left = Enum.sum_by(near, &(&1["remaining"] || 0))

    # Ore actually left, not workers per deposit: they stack, so a crowded field isn't running out.
    if ore_left < @low_home_ore,
      do: memory.ore_short_since || v.tick,
      else: nil
  end

  # Below the floor, the Barracks train before anything is built or researched.
  defp army_floor(acc, v) do
    if length(Roles.fighters(v)) < @army_floor + div(v.tick, @army_floor_ticks),
      do: train_army(acc, v),
      else: acc
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
        not prerequisites?(v, type) -> {:halt, nil}
        gated? and not rich?(v) -> {:halt, nil}
        # Rich, a depot still waits for its workers; the rest of the order goes on.
        gated? and type == "ResourceDepot" -> {:cont, nil}
        site = site(terrain, v, where, avoid) -> {:halt, {type, site}}
        true -> {:cont, nil}
      end
    end)
  end

  # An outpost without a Guard Tower (finished or not) near it gets one, and a second once we are
  # rich: towers are the cheapest defense there is, and outposts are where raiders go. Needs a
  # finished Barracks, like every tower; the first doesn't need us to be rich.
  defp outpost_tower(v, terrain) do
    towers = Enum.map(View.buildings_of(v, "GuardTower"), &View.pos/1)
    wanted = if rich?(v), do: @outpost_towers, else: 1

    if prerequisites?(v, "GuardTower") do
      Roles.outposts(v)
      |> Enum.reject(fn o -> Enum.count(towers, &(View.dist(&1, o) <= @outpost_tower_reach)) >= wanted end)
      |> Enum.find_value(fn o ->
        site = site(terrain, v, {:outpost, o})
        site && {"GuardTower", site}
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

  defp siege_time?(v) do
    build_order_done? = Enum.all?(build_order(v), fn {type, wanted, _, _, _} -> count(v, type) >= wanted end)
    build_order_done? and length(Roles.fighters(v)) >= @siege_after_fighters
  end

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
    if length(View.units_of(v, "Worker")) < @rebuild_workers,
      do: with_reserve(acc, reserve, &train_workers(&1, v)),
      else: acc
  end

  # `spend` may use the reserve too; whatever of it is left stays back afterwards.
  defp with_reserve({cmds, mem, ore}, reserve, spend) do
    {cmds, mem, ore} = spend.({cmds, mem, ore + reserve})
    {cmds, mem, ore - reserve}
  end

  defp train_workers({cmds, mem, ore} = acc, v) do
    with %{"completed" => true} = cc <- v.cc,
         queued = length(cc["production"]),
         true <- length(View.units_of(v, "Worker")) + queued < target_workers(v) and queued < 2,
         true <- ore >= @costs["Worker"] do
      cmd = %{"type" => "Produce", "buildingId" => cc["id"], "unitType" => "Worker"}
      {[cmd | cmds], mem, ore - @costs["Worker"]}
    else
      _ -> acc
    end
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
    lab = Enum.find(View.buildings_of(v, "TechLab"), &(&1["completed"] and &1["research"] == nil))
    upgrade =
      Enum.find(@research, fn u ->
        u not in v.upgrades and u not in v.researching and (u != "SiegeEngineering" or siege_time?(v))
      end)

    if lab && upgrade && ore >= @costs[upgrade] do
      cmd = %{"type" => "Research", "buildingId" => lab["id"], "upgrade" => upgrade}
      {[cmd | cmds], mem, ore - @costs[upgrade]}
    else
      acc
    end
  end

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
    wanted = if siege_time?(v), do: @trebuchets, else: 0

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

  # Every finished Barracks trains non-stop: two soldiers for each archer.
  defp train_army(acc, v) do
    soldiers = length(View.units_of(v, "Soldier"))
    archers = length(View.units_of(v, "Archer"))
    kind = if archers * 2 < soldiers, do: "Archer", else: "Soldier"

    # Rich: fill the queues (the game takes five) so the ore turns into units, not waste.
    queue = if rich?(v), do: 5, else: 2

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
    target =
      v.deposits
      |> Enum.reject(&(&1 in near))
      |> Enum.filter(&safe_ore?(v, &1, avoid))
      |> Enum.min_by(&{View.trip(v, &1), View.dist(View.pos(&1), View.pos(cc)), &1["id"]}, fn -> nil end)

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
  # never a contested deposit between two players), and not where we just lost a building.
  defp safe_ore?(%View{} = v, deposit, avoid) do
    pos = View.pos(deposit)
    View.ours?(v, pos) and not Enum.any?(avoid, &(View.dist(&1, pos) <= 4))
  end

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
          not Enum.any?(ore, &(View.dist(&1, {x, y}) <= 1)) do
        {score.({x, y}, d), {x, y}}
      end

    case Enum.min_by(candidates, &elem(&1, 0), fn -> nil end) do
      nil -> nil
      {_score, site} -> site
    end
  end
end
