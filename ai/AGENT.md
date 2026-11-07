Engineering Standards

### Project
The project ins an open-source desktop suite written in zig 0.17.0.

Priotities, in order:
    1. Correctness and reliablity
    2. Clear ownership and resource managment
    3. Simple, maintainable architecture
    4. Performance (Benched marked)
    5. Protablity and minimal dependencies 
       When considering deps. First we should ask
       1. Can we roll it ourself? 
       2. Is there a zig library that already handles the task
       3. Is there a C/C++ library that we can vender ourself. (Building with build.zig)
       4. System libraries linked against host. 
    6. Project should target a musl libc enviroment
    7. Code perforamnce and small foot print matter. Hardware is no an unlimited resoruce

### Zig Version and Compatibitly 
    * Use zig 0.17.0 unless otherwise told. (zig is managed either by a system build FenrirOS or ZVM)
    * Never assume APIs, always check agaisnt zig std library (zig ships its std library as source code)
        Thus there is no reason to go to the internet to verify how the zig std library works
    * Do not invent functions, types, imports, or library APIs
    * Prefere zig's std over external deps.


### Documentation
Authoritative Sources and Engineering Transparency

AI-assisted development MUST prioritize human understanding, verifiablility, and long-term maintainablity over implementation speed.

## Authoritative references
    * When implementing standards, protocols, file formats, system interfaces, or external APIs, consult the applicable offical specifications, 
      manuals and upstream documentation.
    * Prefer Primary sources over tutorials, examples, blog posts, or AI-Generated explanations.
    * Reference the relevant documentation when writing technical documentation or recording architectural changes
    * Record the specification version, relevantg section, and source URL where practical.
    * Distinguish normative requirments from imiplementation recommendations and project-specific design choices.
    * Never invent references, claim to have consulted unavailable documention or present assumptions as established facts.
    * When authoritative documention is umnavailable or ambiguous, explicity document that uncertainty.
        - In the case that you use thrid pary, tutorials, blogs, etc as a LAST RESORT document that as well.

## Explainable engineering
    * Code MUST be understable and maintainable by a human developer without assistance from the AI that generated it.
    * Prefer straightforward control flow, explict ownership, and clearly defined infterfaces over clever abstractions.
    * Significant architectural changes MUST include an explanation of the problem, proposed solution, alternatives considered, and consquencess.
    * Explain non-obvious algorithms, invariants, assumptions, and iimplementation constraints in the approppriate documention.
    * Comments SHOULD explain why something is done when the reason is not evident from the code.
    * Do not introduce unnecessary abstractions, frameworks, or dependencies that make the implementation harder to reason about.
    * When a requirment or architectural decision is unclear, ask for clarification rather than silently choosing an approach with significan consequences.

## Verification
    * Documention references MUST support the specific claims made.
    * Tests SHOULD be derived from published standasrds and documented requirments where applicable.
    * An implementation MUST NOT be described as standards-compliant solely because it copiles or passes a limited test suite.
    * Know deviations, unsupported features, and unverified assumptions MUST be documented.

## Layout of docs dir

docs/arechitecture.md  - This describs the current implementation of how it actually works. (Ascii graphs and tables welcome)
docs/decisions/ - Why imprtaint archiectual decision were made. (If using git. They should be associated with the commits)
docs/manpages/ - Any userfacing API, setting, commandline flag should be documented following the docs/manpages/template.md


### Enineering Philoshy
This project follows the principles of data-oriented design, resource-conscious programming, and sipmle softaere architecture.

Computere resources asre finite. Memeroy, CPU time, storage, bandwidth, and energy must be treated as limited resources.

Performance and effciency are architectural requirments, not optonal improvments.

Pefer desgins that are understandable, measurable, and economical in their use of resources.

As a project we want to focus on statless desgined. That is having a configur

Date-Oriented Design
    * Organize data around actual access and transformation patterns.
    * Favor contiguous storage when it improves locality and iteration performance.
    * Choose array-of-structures (AoS) or structure of arrays (SoA) according to usage patterns, not dogma.
    * Avoid excessive pointer indirection and fragmented allocations.
    * Precer simple data transformations over unnecessary Objecdt heirarchies
    * minimize redundant state and unnecessary data copying.
    * Consider cache locality, memory layout, and allocation behavior when designing frewquently used systems.
    * Avoid introudicn abstraction layers taht obscure important memroy or performacnes characteristics.

### Shared and Global State
    * Global mutable state is not inherently prohibited.
    * Prefer explicit ownership and well-defined mutation boundaries.
    * Use process-wide state when its lifetime andc access requirments justify it.
    * Document synchronizastion requirments for state shared across threads.
    * Avoid hidden dependencies and uncrontralled muation
    * Do not duplicate shared data unnecessarily.

### Resource-Constrained Design
The project must remain responsize on low-resource hardware.
    * Minimze baseline memory consumption
    * Avoid Unnecessary background services and threads.
    * Prefer event-driven operations or periodic polling
    * Avoid allocations in latency-senstive paths wehre practical.
    * Bound caches and teporary storage according to explict policies.
    * Avoid retaining resources that are no longer needed.
    * Make nonessential features optional where practical.
    * Avoid unnecessary work when project is idle.
    * Consder memory pressure and allocation failure during design.
    * Do nnot assume abundant RAM,CPU cores, or GPU capablitities.

### Performacne Engineering
    * Establish resource budgets for major subsystems.
    * Measure startup time, idle CPU usage, emory consumption, and interaction latency.
    * Consider both average and worst-case latency.
    * Distinghusih algorithmic improvements from micro-optimizations.
    * Avoid introudicnt additional processes, threads, or IPC without clear benefits.
    * Benchmark performance-sensitive changes where practical.
    * Compare performance againsst a baseline before claiming improvements.
    * Prefer architectural effciencey before low-level optimization.

### Architecture References 
Primary reference:
https://aosabook.org/en/
Consult relevant examples from:
    * The architecture of Open Source 
    * Applications, Volumes 1 & 2. The Performacne of Open Source applications
    * 500 lines or less

Use these works to understand engeering tradoffs, not as manditory dogma 

When proposing significant architecutural changes:
    1. Idenity the problem to be solved
    2. Explain the proposed design.
    3. Consider simpler alternatives
    4. Anaylize memmory and CPU implications.
    5. Identify owership and lifetime requirments
    6. Consider how the design behaves under resource pressure
    7. Explain why the additional complexity is justified. 


### Coding Standards 
    * Follow the offical zig Style Guide (zig fmt on all .zig files)
    * Prefer const over var whenever mutation is unnecessary
    * Prefer explicit, readable code over clever abstractions. 
        (real humans need to be able to figure out how this works)
    * Avoid unnecessary generic programming and excessive comptime complexity
    * Avoid unnecessary Heap allocations
    * Keep Functions focused on a single responsiblity
    * Use meaningful names consistend wit hthe surrounding code. 
    * Avoid redundant naming such as Data, Manger, Utils, or Context when more descriptive names exist.
    * Do not create abstraction layers without a concrete need.
    * Reuse existing project functionality rather than duplicate it.

### Memeroy and Resource Managment
    * Every allocations mush have a clearly understood owner. 
    * Every owned allocation must have a corresponding cleanup strategy.
    * Document ownership when it is not abvious from the API
    * Prefered scoped cleanup using defer and errdefer.
    * Use errdeff to clean up partially initalised resources when returning errors.
    * Never return pointers or slices to expired stack storage.
    * Never retain bowrrowdd memory beyond its valid lifetime.
    * Do not use 

### Security and input Validation
    * Treat files, configurations, user input, and external data as untrusted.
    * Validate lenghts, offsets, indices, and interager conversions.
    * Handle malformed input without underfined behavior.
    * Never assume external date is null-terminated
    * Avoid unsafe pointer mainupulation when safe alternatives exist.
    * Do not introduce command execution or arbitary access without justification.

### Testing and Verfication 
    * Add testing for new nontrivial logic.
    * Whenever a bug is found a test should be created to stop regression
    * Test edge cases, invalied input, and failure paths.
    * Run zig build after code changes
    * Run zig build test before any commits.
    * Do not claim code compiles are test pass unless those commands actually succeded.
    * If varification is impossible, explain why
        * Print [PASSED] Test name
        * Print [Failed] Test name
        * Passed in green/ Failed in red unless NO_COLOR is passed
    * Any external test (Not zig's unit test) such as scripts, programs, etc
    go in test dir at project root level.