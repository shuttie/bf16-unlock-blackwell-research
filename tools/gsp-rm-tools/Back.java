import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Instruction;
import java.util.ArrayList;
public class Back extends GhidraScript {
    public void run() throws Exception {
        String arg = getScriptArgs()[0];
        int n = Integer.parseInt(getScriptArgs()[1]);
        for (String s : arg.split(",")) {
            Address a = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(s.trim());
            if (getInstructionAt(a) == null) disassemble(a);
            Instruction insn = getInstructionAt(a);
            if (insn == null) { println(s + " <no insn>"); continue; }
            ArrayList<Instruction> seq = new ArrayList<>();
            Instruction cur = insn;
            for (int i = 0; i < n && cur != null; i++) { seq.add(0, cur); cur = cur.getPrevious(); }
            StringBuilder sb = new StringBuilder(s);
            for (Instruction x : seq) sb.append(" | ").append(x.getAddress()).append(": ").append(x.toString());
            println(sb.toString());
        }
    }
}
