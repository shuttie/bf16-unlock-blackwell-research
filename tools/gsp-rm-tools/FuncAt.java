import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
public class FuncAt extends GhidraScript {
    public void run() throws Exception {
        for (String s : getScriptArgs()[0].split(",")) {
            Address a = currentProgram.getAddressFactory().getDefaultAddressSpace().getAddress(s.trim());
            Function f = getFunctionContaining(a);
            Instruction insn = getInstructionAt(a);
            String fdesc = (f == null) ? "<none>" : (f.getEntryPoint() + " " + f.getName() + " size=0x" + Long.toHexString(f.getBody().getNumAddresses()));
            String idesc = (insn == null) ? "<no insn>" : insn.toString();
            println(s + " : func=" + fdesc + " | insn=" + idesc);
        }
    }
}
