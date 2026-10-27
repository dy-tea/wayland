module wayland

// signed 24.8 fixed point value
pub type Fixed = i32

// create a new Fixed value from f64
pub fn Fixed.new(v f64) Fixed {
	return Fixed(v * 256.0)
}

// get the corresponding f64 value for the Fixed
pub fn (f Fixed) f64() f64 {
	return f64(f) / 256.0
}
