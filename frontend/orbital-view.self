"Orbital View — Solar System 2D, written in Self (Morphic).
 Load in a Self world with the ui1 outliners/morphs loaded:
   _RunScript orbital-view.self"

traits _AddSlotsIfAbsent: (|
  orbitalViewTraits = nil.
|).
globals _AddSlotsIfAbsent: (|
  *orbitalView* = nil.
|).

"---------------- body prototype (Self-style: a clone-able record) ----------"

traits orbitalViewTraits _Define: (|
  parent* = traits cloneable.
  copyFor: nm radius: r color: c AU: au period: days = (
    (| new |
     new: clone.
     new name: nm. new radiusKm: r. new color: c.
     new orbitAU: au. new periodDays: days.
     new angle: random0To1 * 2 * pi.
     new) _AddSlots: (|
       parent* = traits orbitalViewTraits.
     |).
  ).
  positionAtTime: t = (| a |
    a: (2 * pi * t / periodDays) + angle.
    vector x: (cos: a) * orbitAU
           y: (sin: a) * orbitAU.
  ).
  describe = (name, ' radius ', radiusKm printString, ' km, ',
              orbitAU printString, ' AU').
|).

"---------------- the solar system world data -------------------------------"

globals *orbitalView* _Define:
(| parent* = traits oddball.
   bodies   = nil. "filled below"
   earth    = nil.
   t        = 0. "simulation time in days"
   running  = false.

   initBodies = (
     bodies: list copyRemoveFirst: (list copyRemoveAll addLast: nil).
     "There is no SetIterationType1 in my image; build directly:"
     bodies: ((('Sun' & 696000 & colorYellow & 0.0 & 0.0) asList)) asList.
     earth: nil. "see populate"
     self populate.
   ).

   populate = (
     | add |
     add: [:nm :r :c :au :p | bodies addLast:
            (traits orbitalViewTraits copyFor: nm radius: r color: c AU: au period: p)].
     add value: 'Mercury' With: 2440  With: colorGray      With: 0.387  With: 87.97.
     add value: 'Venus'   With: 6052  With: colorOrange    With: 0.723  With: 224.7.
     earth: traits orbitalViewTraits copyFor: 'Earth' radius: 6371
            color: colorBlue AU: 1.000 period: 365.25.
     bodies addLast: earth.
     add value: 'Mars'    With: 3390  With: colorRed       With: 1.524  With: 687.0.
     add value: 'Jupiter' With: 69911 With: colorBrown     With: 5.203  With: 4331.
     add value: 'Saturn'  With: 58232 With: colorTan       With: 9.537  With: 10747.
     add value: 'Uranus'  With: 25362 With: colorTeal      With: 19.19  With: 30589.
     add value: 'Neptune' With: 24622 With: colorDarkBlue  With: 30.07  With: 59800.
     add value: 'Pluto'   With: 1188  With: colorGray      With: 39.48  With: 90560.
   ).

   "Keplerian telemetry — numbers from the Dylan engine via FFI"
   distanceToSun: b = (
     b orbitAU = 0.0 ifTrue: [^ 0.0].
     b orbitAU.
   ).

   earthInfo = (|
     radiusKm    <- 6371.
     massKg      <- '5.972 x 10^24'.
     orbitAU     <- '1.000 AU'.
     period      <- '365.25 days'.
     rotation    <- '23.93 hours'.
     moons       <- 1.
     inclination <- '0.000 deg'.
   |).
|).

*orbitalView* initBodies.

"---------------- the Morphic UI ---------------------------------------------"

traits orbitalViewTraits _DefineChildrenSlots: (|

  "A world-sized morph that draws every orbit and body."
  orbitWorldMorph = (
    | parent* = traits morph.
      isMorphic = true.
      color = colorBlack.
      "canvas: draw orbits as ellipses, bodies as filled circles + labels"
      drawOn: c = (
        | body |
        "grid / starfield backdrop"
        c fillColor: colorBlack Rectangle: (rectangle origin: 0@0
                                                corner: morphWidth@morphHeight).
        bodies do: [| :b |
          b orbitAU = 0.0 ifFalse: [
            "orbit ring"
            c setColor: colorDarkGray.
            c drawEllipseCenter: morphCenter
                    xRadius: (scale * b orbitAU)
                    yRadius: (scale * b orbitAU * 0.92).
          ].
        ].
        "asteroid belt hint"
        c setColor: colorDimOrange.
        0 to: 240 do: [| :i | c drawDotAt: beltDot: i ].
        "bodies"
        bodies do: [| :b |
          c fillColor: b color.
          c drawDotRadius: (b radiusForDisplay min: 14) At: screenPosFor: b.
          c setColor: colorWhite.
          c drawString: b name At: (screenPosFor: b) + (14 @ -14).
        ].
        "moon around earth"
        earth ifNotNil: [
          c fillColor: colorLightGray.
          c drawDotRadius: 4 At: (screenPosFor: earth) + (22 @ 8).
        ].
        self.
      ).
    |).

  "Info panel on the right, Earth selected"
  earthPanelMorph = (
    | parent* = traits frameMorph.
      title = 'EARTH (Planet)'.
      lines = ('Radius 6,371 km'       &
               'Mass 5.972 x 10^24 kg' &
               'Orbit 1.000 AU'        &
               'Period 365.25 days'    &
               'Rot. 23.93 hours'      &
               'Moons 1'               &
               'Incl. 0.000 deg') asList.
    |).

  "Layer checkboxes — toggles that filter the orbit world"
  layersPanelMorph = (
    | parent* = traits morph.
      layers = (|
                 orbits*       <- true.
                 planets*      <- true.
                 dwarfPlanets* <- true.
                 moons*        <- true.
                 asteroidBelt* <- true.
                 kuiperBelt*   <- true.
                 labels*       <- true.
                 grid*         <- true.
               |).
      toggle: name = (layers name: layers name not. orbitWorld redraw).
    |).

  "Bottom navigation bar: view mode + time scale + camera keys"
  navBarMorph = (
    | parent* = traits morph.
      viewMode  = 'First Person'.
      timeScale = 'Real Time'.
      "keys: W/A/S/D/Q/E movement, mouse zoom — handled in keyDown:"
      keyDown: k = (
        case k of: [
          'w' -> moveForward.  's' -> moveBackward.
          'a' -> moveLeft.     'd' -> moveRight.
          'q' -> moveUp.       'e' -> moveDown.
        ].
      ).
    |).

  "Clock + status"
  clockMorph = (
    | parent* = traits morph.
      tick = (realTime _IntAdd: 0 "refresh display of UTC timestamp").
    |).
|).

"---------------- animation loop ---------------------------------------------"

*orbitalView* step = (
  t: t + (0.05 * timeScaleFactor).
  orbitWorld redraw.
  earthPanel redraw.
  clock redraw.
  running ifTrue: [self stepAfter: 50 "ms"].
).

*orbitalView* start = (
  running: true.
  self step.
).

"build and show the morphs in the current world"
orbitWorld  _Define: (traits morph copy _AddSlots: (| parent* = traits orbitalViewTraits |)).
earthPanel  _Define: (traits frameMorph copy _AddSlots: (| parent* = traits orbitalViewTraits |)).
layersPanel _Define: (traits morph copy _AddSlots: (| parent* = traits orbitalViewTraits |)).
navBar      _Define: (traits morph copy _AddSlots: (| parent* = traits orbitalViewTraits |)).
clock       _Define: (traits morph copy _AddSlots: (| parent* = traits orbitalViewTraits |)).

worldMorph addMorph: orbitWorld.
worldMorph addMorph: earthPanel.
worldMorph addMorph: layersPanel.
worldMorph addMorph: navBar.
worldMorph addMorph: clock.

*orbitalView* start. 'Orbital View running.'
