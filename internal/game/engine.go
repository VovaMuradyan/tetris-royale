package game

import (
	"encoding/binary"
	"fmt"
	"sort"
)

const (
	BoardWidth  = 10
	VisibleRows = 20
	HiddenRows  = 2
	BoardHeight = VisibleRows + HiddenRows

	TickRate          = 60
	InputDelayTicks   = 2
	MaxInputLeadTicks = 12
	MaxInputLagTicks  = 120

	FixedShift = 16
	FixedOne   = int64(1 << FixedShift)

	GravityBaseTicks = 48
	MinGravityTicks  = 4
	LockDelayTicks   = 30
	QueueCap         = 32
)

type Fixed int64

func FromCell(v int) Fixed {
	return Fixed(int64(v) * FixedOne)
}

func Cell(v Fixed) int {
	return int(int64(v) / FixedOne)
}

type Piece uint8

const (
	PieceI Piece = iota
	PieceJ
	PieceL
	PieceO
	PieceS
	PieceT
	PieceZ
	PieceNone Piece = 255
)

type InputAction uint8

const (
	ActionNone InputAction = iota
	ActionLeft
	ActionRight
	ActionRotateCW
	ActionRotateCCW
	ActionSoftDrop
	ActionHardDrop
)

type Input struct {
	Tick       uint64
	Seq        uint64
	Action     InputAction
	ClientHash string
}

type ActivePiece struct {
	Kind     Piece
	Rotation uint8
	X        Fixed
	Y        Fixed
}

type State struct {
	Tick       uint64
	Board      [BoardHeight][BoardWidth]uint8
	Active     ActivePiece
	Queue      [QueueCap]Piece
	QueueLen   int
	RNG        uint64
	GravityAcc int64
	LockTicks  int64
	Lines      int64
	Score      int64
	GameOver   bool
}

type ActiveSnapshot struct {
	Kind     uint8 `msgpack:"kind"`
	Rotation uint8 `msgpack:"rotation"`
	X        int64 `msgpack:"x"`
	Y        int64 `msgpack:"y"`
}

type Snapshot struct {
	Tick     uint64         `msgpack:"tick"`
	Board    [][]uint8      `msgpack:"board"`
	Active   ActiveSnapshot `msgpack:"active"`
	Queue    []uint8        `msgpack:"queue"`
	RNG      uint64         `msgpack:"rng"`
	Lines    int64          `msgpack:"lines"`
	Score    int64          `msgpack:"score"`
	Gravity  int64          `msgpack:"gravity_acc"`
	Lock     int64          `msgpack:"lock_ticks"`
	GameOver bool           `msgpack:"game_over"`
	Hash     string         `msgpack:"hash"`
}

type point struct {
	x int
	y int
}

var pieceCells = [7][4][4]point{
	// I
	{
		{{0, 1}, {1, 1}, {2, 1}, {3, 1}},
		{{2, 0}, {2, 1}, {2, 2}, {2, 3}},
		{{0, 2}, {1, 2}, {2, 2}, {3, 2}},
		{{1, 0}, {1, 1}, {1, 2}, {1, 3}},
	},
	// J
	{
		{{0, 0}, {0, 1}, {1, 1}, {2, 1}},
		{{1, 0}, {2, 0}, {1, 1}, {1, 2}},
		{{0, 1}, {1, 1}, {2, 1}, {2, 2}},
		{{1, 0}, {1, 1}, {0, 2}, {1, 2}},
	},
	// L
	{
		{{2, 0}, {0, 1}, {1, 1}, {2, 1}},
		{{1, 0}, {1, 1}, {1, 2}, {2, 2}},
		{{0, 1}, {1, 1}, {2, 1}, {0, 2}},
		{{0, 0}, {1, 0}, {1, 1}, {1, 2}},
	},
	// O
	{
		{{1, 0}, {2, 0}, {1, 1}, {2, 1}},
		{{1, 0}, {2, 0}, {1, 1}, {2, 1}},
		{{1, 0}, {2, 0}, {1, 1}, {2, 1}},
		{{1, 0}, {2, 0}, {1, 1}, {2, 1}},
	},
	// S
	{
		{{1, 0}, {2, 0}, {0, 1}, {1, 1}},
		{{1, 0}, {1, 1}, {2, 1}, {2, 2}},
		{{1, 1}, {2, 1}, {0, 2}, {1, 2}},
		{{0, 0}, {0, 1}, {1, 1}, {1, 2}},
	},
	// T
	{
		{{1, 0}, {0, 1}, {1, 1}, {2, 1}},
		{{1, 0}, {1, 1}, {2, 1}, {1, 2}},
		{{0, 1}, {1, 1}, {2, 1}, {1, 2}},
		{{1, 0}, {0, 1}, {1, 1}, {1, 2}},
	},
	// Z
	{
		{{0, 0}, {1, 0}, {1, 1}, {2, 1}},
		{{2, 0}, {1, 1}, {2, 1}, {1, 2}},
		{{0, 1}, {1, 1}, {1, 2}, {2, 2}},
		{{1, 0}, {0, 1}, {1, 1}, {0, 2}},
	},
}

var normalKicks = map[int][5]point{
	1:  {{0, 0}, {-1, 0}, {-1, -1}, {0, 2}, {-1, 2}},
	4:  {{0, 0}, {1, 0}, {1, 1}, {0, -2}, {1, -2}},
	6:  {{0, 0}, {1, 0}, {1, 1}, {0, -2}, {1, -2}},
	9:  {{0, 0}, {-1, 0}, {-1, -1}, {0, 2}, {-1, 2}},
	11: {{0, 0}, {1, 0}, {1, -1}, {0, 2}, {1, 2}},
	14: {{0, 0}, {-1, 0}, {-1, 1}, {0, -2}, {-1, -2}},
	12: {{0, 0}, {-1, 0}, {-1, 1}, {0, -2}, {-1, -2}},
	3:  {{0, 0}, {1, 0}, {1, -1}, {0, 2}, {1, 2}},
}

var iKicks = map[int][5]point{
	1:  {{0, 0}, {-2, 0}, {1, 0}, {-2, -1}, {1, 2}},
	4:  {{0, 0}, {2, 0}, {-1, 0}, {2, 1}, {-1, -2}},
	6:  {{0, 0}, {-1, 0}, {2, 0}, {-1, 2}, {2, -1}},
	9:  {{0, 0}, {1, 0}, {-2, 0}, {1, -2}, {-2, 1}},
	11: {{0, 0}, {2, 0}, {-1, 0}, {2, 1}, {-1, -2}},
	14: {{0, 0}, {-2, 0}, {1, 0}, {-2, -1}, {1, 2}},
	12: {{0, 0}, {1, 0}, {-2, 0}, {1, -2}, {-2, 1}},
	3:  {{0, 0}, {-1, 0}, {2, 0}, {-1, 2}, {2, -1}},
}

func NewState(seed uint64) State {
	s := State{RNG: normalizeSeed(seed)}
	s = ensureQueue(s, 7)
	s = spawnNext(s)
	return s
}

func Step(s State, inputs []Input) State {
	if len(inputs) > 1 {
		sort.SliceStable(inputs, func(i, j int) bool {
			if inputs[i].Tick == inputs[j].Tick {
				return inputs[i].Seq < inputs[j].Seq
			}
			return inputs[i].Tick < inputs[j].Tick
		})
	}
	for _, input := range inputs {
		s = ApplyInput(s, input)
	}
	s = advanceGravity(s)
	s.Tick++
	return s
}

func ApplyInput(s State, input Input) State {
	if s.GameOver {
		return s
	}

	switch input.Action {
	case ActionLeft:
		return move(s, -1, 0)
	case ActionRight:
		return move(s, 1, 0)
	case ActionRotateCW:
		return rotate(s, 1)
	case ActionRotateCCW:
		return rotate(s, -1)
	case ActionSoftDrop:
		next, ok := tryMove(s, 0, 1)
		if ok {
			next.Score++
			return next
		}
		return s
	case ActionHardDrop:
		return hardDrop(s)
	default:
		return s
	}
}

func (s State) Snapshot() Snapshot {
	return Snapshot{
		Tick:     s.Tick,
		Board:    s.BoardRows(),
		Active:   ActiveSnapshot{Kind: uint8(s.Active.Kind), Rotation: s.Active.Rotation, X: int64(s.Active.X), Y: int64(s.Active.Y)},
		Queue:    s.QueueSlice(s.QueueLen),
		RNG:      s.RNG,
		Lines:    s.Lines,
		Score:    s.Score,
		Gravity:  s.GravityAcc,
		Lock:     s.LockTicks,
		GameOver: s.GameOver,
		Hash:     HashHex(s),
	}
}

func (s State) BoardRows() [][]uint8 {
	rows := make([][]uint8, BoardHeight)
	for y := 0; y < BoardHeight; y++ {
		row := make([]uint8, BoardWidth)
		copy(row, s.Board[y][:])
		rows[y] = row
	}
	return rows
}

func (s State) QueueSlice(limit int) []uint8 {
	if limit > s.QueueLen {
		limit = s.QueueLen
	}
	out := make([]uint8, limit)
	for i := 0; i < limit; i++ {
		out[i] = uint8(s.Queue[i])
	}
	return out
}

func GravityInterval(s State) int64 {
	level := s.Lines / 10
	interval := int64(GravityBaseTicks) - level*4
	if interval < MinGravityTicks {
		return MinGravityTicks
	}
	return interval
}

func move(s State, dx, dy int) State {
	next, ok := tryMove(s, dx, dy)
	if !ok {
		return s
	}
	if grounded(next) {
		next.LockTicks = 0
	}
	return next
}

func tryMove(s State, dx, dy int) (State, bool) {
	a := s.Active
	a.X += FromCell(dx)
	a.Y += FromCell(dy)
	if collides(s, a) {
		return s, false
	}
	s.Active = a
	return s, true
}

func rotate(s State, dir int) State {
	if s.Active.Kind == PieceO {
		next := s
		next.Active.Rotation = uint8((int(next.Active.Rotation) + dir + 4) % 4)
		return next
	}

	from := s.Active.Rotation & 3
	to := uint8((int(from) + dir + 4) % 4)
	for _, kick := range kicks(s.Active.Kind, from, to) {
		a := s.Active
		a.Rotation = to
		a.X += FromCell(kick.x)
		a.Y += FromCell(kick.y)
		if !collides(s, a) {
			s.Active = a
			if grounded(s) {
				s.LockTicks = 0
			}
			return s
		}
	}
	return s
}

func hardDrop(s State) State {
	dropped := int64(0)
	for {
		next, ok := tryMove(s, 0, 1)
		if !ok {
			break
		}
		dropped++
		s = next
	}
	s.Score += dropped * 2
	return lockPiece(s)
}

func advanceGravity(s State) State {
	if s.GameOver {
		return s
	}

	movedByGravity := false
	s.GravityAcc++
	if s.GravityAcc >= GravityInterval(s) {
		s.GravityAcc = 0
		next, ok := tryMove(s, 0, 1)
		if ok {
			s = next
			movedByGravity = true
		}
	}

	if grounded(s) {
		if !movedByGravity {
			s.LockTicks++
		}
		if s.LockTicks >= LockDelayTicks {
			return lockPiece(s)
		}
	} else {
		s.LockTicks = 0
	}

	return s
}

func grounded(s State) bool {
	a := s.Active
	a.Y += FromCell(1)
	return collides(s, a)
}

func lockPiece(s State) State {
	if s.GameOver {
		return s
	}
	for _, c := range activeCells(s.Active) {
		if c.y < 0 {
			s.GameOver = true
			return s
		}
		if c.y >= BoardHeight || c.x < 0 || c.x >= BoardWidth {
			s.GameOver = true
			return s
		}
		s.Board[c.y][c.x] = uint8(s.Active.Kind) + 1
	}
	s.LockTicks = 0
	s.GravityAcc = 0
	s = clearLines(s)
	return spawnNext(s)
}

func clearLines(s State) State {
	var next [BoardHeight][BoardWidth]uint8
	writeY := BoardHeight - 1
	cleared := int64(0)

	for y := BoardHeight - 1; y >= 0; y-- {
		full := true
		for x := 0; x < BoardWidth; x++ {
			if s.Board[y][x] == 0 {
				full = false
				break
			}
		}
		if full {
			cleared++
			continue
		}
		next[writeY] = s.Board[y]
		writeY--
	}

	s.Board = next
	if cleared > 0 {
		level := s.Lines/10 + 1
		lineScores := [5]int64{0, 100, 300, 500, 800}
		s.Score += lineScores[cleared] * level
		s.Lines += cleared
	}
	return s
}

func spawnNext(s State) State {
	s = ensureQueue(s, 7)
	piece := s.Queue[0]
	for i := 1; i < s.QueueLen; i++ {
		s.Queue[i-1] = s.Queue[i]
	}
	s.QueueLen--
	s.Active = ActivePiece{Kind: piece, Rotation: 0, X: FromCell(3), Y: FromCell(0)}
	if collides(s, s.Active) {
		s.GameOver = true
	}
	return ensureQueue(s, 7)
}

func ensureQueue(s State, min int) State {
	for s.QueueLen < min {
		s = appendBag(s)
	}
	return s
}

func appendBag(s State) State {
	bag := [7]Piece{PieceI, PieceJ, PieceL, PieceO, PieceS, PieceT, PieceZ}
	for i := len(bag) - 1; i > 0; i-- {
		s.RNG = nextRand(s.RNG)
		j := int(s.RNG % uint64(i+1))
		bag[i], bag[j] = bag[j], bag[i]
	}
	for _, piece := range bag {
		if s.QueueLen >= QueueCap {
			break
		}
		s.Queue[s.QueueLen] = piece
		s.QueueLen++
	}
	return s
}

func activeCells(a ActivePiece) [4]point {
	var out [4]point
	if a.Kind > PieceZ {
		return out
	}
	baseX := Cell(a.X)
	baseY := Cell(a.Y)
	cells := pieceCells[a.Kind][a.Rotation&3]
	for i, c := range cells {
		out[i] = point{x: baseX + c.x, y: baseY + c.y}
	}
	return out
}

func collides(s State, a ActivePiece) bool {
	if a.Kind > PieceZ {
		return true
	}
	for _, c := range activeCells(a) {
		if c.x < 0 || c.x >= BoardWidth || c.y >= BoardHeight {
			return true
		}
		if c.y >= 0 && s.Board[c.y][c.x] != 0 {
			return true
		}
	}
	return false
}

func kicks(piece Piece, from, to uint8) [5]point {
	key := int(from&3)*4 + int(to&3)
	if piece == PieceI {
		return iKicks[key]
	}
	return normalKicks[key]
}

func normalizeSeed(seed uint64) uint64 {
	if seed == 0 {
		return 0x9e3779b97f4a7c15
	}
	return seed
}

func nextRand(x uint64) uint64 {
	x = normalizeSeed(x)
	x ^= x << 13
	x ^= x >> 7
	x ^= x << 17
	return normalizeSeed(x)
}

func HashHex(s State) string {
	return fmt.Sprintf("%016x", MerkleHash(s))
}

func MerkleHash(s State) uint64 {
	var leaves [32]uint64
	count := 0
	for y := 0; y < BoardHeight; y++ {
		h := fnvOffset
		h = mixByte(h, byte(y))
		for x := 0; x < BoardWidth; x++ {
			h = mixByte(h, s.Board[y][x])
		}
		leaves[count] = h
		count++
	}

	h := fnvOffset
	h = mixU64(h, s.Tick)
	h = mixByte(h, byte(s.Active.Kind))
	h = mixByte(h, s.Active.Rotation)
	h = mixU64(h, uint64(int64(s.Active.X)))
	h = mixU64(h, uint64(int64(s.Active.Y)))
	h = mixU64(h, uint64(s.Lines))
	h = mixU64(h, uint64(s.Score))
	h = mixU64(h, s.RNG)
	h = mixU64(h, uint64(s.GravityAcc))
	h = mixU64(h, uint64(s.LockTicks))
	h = mixU64(h, uint64(s.QueueLen))
	for i := 0; i < s.QueueLen; i++ {
		h = mixByte(h, byte(s.Queue[i]))
	}
	if s.GameOver {
		h = mixByte(h, 1)
	} else {
		h = mixByte(h, 0)
	}
	leaves[count] = h
	count++

	for count > 1 {
		write := 0
		for i := 0; i < count; i += 2 {
			left := leaves[i]
			right := left
			if i+1 < count {
				right = leaves[i+1]
			}
			parent := fnvOffset
			parent = mixU64(parent, left)
			parent = mixU64(parent, right)
			leaves[write] = parent
			write++
		}
		count = write
	}
	return leaves[0]
}

const (
	fnvOffset uint64 = 14695981039346656037
	fnvPrime  uint64 = 1099511628211
)

func mixByte(h uint64, b byte) uint64 {
	h ^= uint64(b)
	h *= fnvPrime
	return h
}

func mixU64(h uint64, value uint64) uint64 {
	var buf [8]byte
	binary.LittleEndian.PutUint64(buf[:], value)
	for _, b := range buf {
		h = mixByte(h, b)
	}
	return h
}
