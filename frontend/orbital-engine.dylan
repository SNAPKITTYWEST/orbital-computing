Module: orbital-engine
Language: infix-dylan

define library orbital-engine
  use common-dylan;
  use transcendental;
  export orbital-engine;
end library;

define module orbital-engine
  use common-dylan;
  use transcendental;
  export <body>, make-body, position-at-time, distance-au,
         orbital-period, <vec3>, make-vec3;
end module;

define class <body> (<object>)
  slot body-name :: <string>, required-init-keyword: name:;
  slot body-radius-km :: <double-float>, required-init-keyword: radius:;
  slot body-semi-major-axis :: <double-float>, required-init-keyword: au:;
  slot body-period-days :: <double-float>, required-init-keyword: period:;
  slot body-phase :: <double-float>, init-value: 0.0d0, init-keyword: phase:;
end class;

define class <vec3> (<object>)
  slot vec-x :: <double-float>, init-keyword: x:, init-value: 0.0d0;
  slot vec-y :: <double-float>, init-keyword: y:, init-value: 0.0d0;
  slot vec-z :: <double-float>, init-keyword: z:, init-value: 0.0d0;
end class;

define function make-vec3 (#key x = 0.0d0, y = 0.0d0, z = 0.0d0)
    => (v :: <vec3>)
  make(<vec3>, x: x, y: y, z: z)
end;

define method make-body (name :: <string>, radius :: <integer>,
                         au :: <float>, period :: <float>)
    => (b :: <body>)
  make(<body>, name: name,
       radius: as(<double-float>, radius),
       au: as(<double-float>, au),
       period: as(<double-float>, period))
end method;

"Mean anomaly at time t (days since epoch), circular Keplerian model."
define method mean-anomaly (b :: <body>, t :: <double-float>)
    => (theta :: <double-float>)
  let tau = 2.0d0 * $pi;
  modulo(b.body-phase + tau * t / b.body-period-days, tau)
end method;

define method position-at-time (b :: <body>, t :: <double-float>)
    => (v :: <vec3>)
  if (b.body-semi-major-axis <= 0.0d0)
    make-vec3()
  else
    let theta = mean-anomaly(b, t);
    make-vec3(x: b.body-semi-major-axis * cos(theta),
              y: b.body-semi-major-axis * sin(theta),
              z: 0.0d0)
  end if
end method;

define generic distance-au (a :: <vec3>, b :: <vec3>) => (d :: <double-float>);

define method distance-au (a :: <vec3>, b :: <vec3>) => (d :: <double-float>)
  let dx = a.vec-x - b.vec-x;
  let dy = a.vec-y - b.vec-y;
  let dz = a.vec-z - b.vec-z;
  sqrt(dx * dx + dy * dy + dz * dz)
end method;

define method orbital-period (b :: <body>) => (days :: <double-float>)
  b.body-period-days
end method;

"Earth's canonical telemetry (matches the UI panel)"
define method earth-body () => (b :: <body>)
  make-body("Earth", 6371, 1.000, 365.25)
end method;
