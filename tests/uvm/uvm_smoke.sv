// Minimal UVM test against the bundled library. Built WITHOUT UVM_NO_DPI so
// UVM's DPI-C imports (regex, command-line processing) resolve against xezim's
// built-in implementation.
`include "uvm_macros.svh"

module top;
  import uvm_pkg::*;

  class smoke_test extends uvm_test;
    `uvm_component_utils(smoke_test)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      `uvm_info("SMOKE", "UVM smoke test running", UVM_LOW)
      #10;
      phase.drop_objection(this);
    endtask
  endclass

  initial run_test("smoke_test");
endmodule
