package common;

// Shared types for the RV32I core.

typedef Bit#(32) Word;
typedef Bit#(5)  RIdx;


typedef enum { ALU, LUI, AUIPC, JAL, JALR, BRANCH, LOAD, STORE, FENCE, ECALL, EBREAK, ILLEGAL }
  IType deriving (Bits, Eq, FShow);

typedef enum { Add, Sub, Sll, Slt, Sltu, Xor, Srl, Sra, Or, And }
  AluOp deriving (Bits, Eq, FShow);

typedef struct {
  IType   iType;
  AluOp   aluOp;
  Bit#(3) funct3;   // branch condition / load-store width
  RIdx    rd;       // 0 when the instruction does not write a register
  RIdx    rs1;
  RIdx    rs2;
  Bool    useRs1;
  Bool    useRs2;
  Bool    srcImm;   // ALU second operand is the immediate
  Word    imm;
} DecodedInst deriving (Bits, Eq, FShow);

// Fetch -> Decode
typedef struct {
  Word pc;
  Word inst;
  Bool epoch;
} F2D deriving (Bits, Eq, FShow);

// Decode -> Execute
typedef struct {
  Word        pc;
  Word        inst;
  DecodedInst dInst;
  Word        rv1;
  Word        rv2;
  Bool        epoch;
} D2E deriving (Bits, Eq, FShow);

// Execute -> Writeback (loads waiting for their memory response)
typedef struct {
  Word    pc;
  Word    inst;
  RIdx    rd;
  Bit#(3) funct3;
  Word    addr;
} E2W deriving (Bits, Eq, FShow);

// Request to a BRAM-style memory port. Reads return one response, in order,
// one or more cycles later; writes produce no response.
typedef struct {
  Bool    write;
  Bit#(4) byteEn;   // byte lanes to write (data already shifted into place)
  Word    addr;
  Word    data;
} MemReq deriving (Bits, Eq, FShow);

function MemReq memRead(Word addr) = MemReq { write: False, byteEn: 0, addr: addr, data: 0 };

endpackage
