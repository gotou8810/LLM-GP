
        // Database of all TEP Plant elements (Nodes and Streams)
        const plantData = {
            // ----- UNITS -----
            mixer: {
                title: "Mixer (混合器)",
                subtitle: "原料供給・循環リサイクルガスの合流器",
                status: "normal",
                description: "Stream 1〜4の原料供給、Stripperからの回収ガス、SeparatorからCompressorを経由した未反応回収ガスを混合し、最適な圧力・流量バランスで反応器(Stream 6)に供給する接合点です。定常運転時の圧力および組成制御の基盤点となります。",
                variables: [
                    { name: "XMEAS(1)", role: "測定変数 (A供給量)", desc: "原料A供給ストリームの瞬時流量" },
                    { name: "XMEAS(2)", role: "測定変数 (D供給量)", desc: "原料D供給ストリームの瞬時流量" },
                    { name: "XMEAS(3)", role: "測定変数 (E供給量)", desc: "原料E供給ストリームの瞬時流量" },
                    { name: "XMEAS(4)", role: "測定変数 (A/C/B供給量)", desc: "原料A, C, Bを含む第4フィードストリームの瞬時流量" },
                    { name: "XMV(1)", role: "操作変数", desc: "D供給流量制御バルブ" },
                    { name: "XMV(2)", role: "操作変数", desc: "E供給流量制御バルブ" },
                    { name: "XMV(3)", role: "操作変数", desc: "A供給流量制御バルブ" },
                    { name: "XMV(4)", role: "操作変数", desc: "A/C/B供給流量制御バルブ" }
                ],
                twin: null
            },
            reactor: {
                title: "Reactor (反応器)",
                subtitle: "エキソサーミック（発熱性）気相化学反応容器",
                status: "completed",
                description: "プラントの中核。気相中で4つの並行・後続反応（A + C + D → G、A + C + E → Hなど）が進行します。反応は激しい発熱を伴うため、内蔵冷却コイル（CW）を流れる冷却水（XMV 10）により厳密な温度・圧力管理が要求されます。反応圧力は生成ガスの体積と反応熱に直接的に連動します。",
                variables: [
                    { name: "XMEAS(7)", role: "測定変数 (反応圧力)", desc: "本反応ユニットの主圧力。デジタルツイン構築完了。" },
                    { name: "XMEAS(9)", role: "測定変数 (反応温度)", desc: "反応器の気相温度。冷却水と反応速度の高度な非線形依存。現在の最適化ターゲット。" },
                    { name: "XMEAS(6)", role: "測定変数 (全フィード量)", desc: "反応器に入る全フィードガスの流量（Stream 6）" },
                    { name: "XMEAS(8)", role: "測定変数 (液位)", desc: "凝縮生成液が反応器底に蓄積する液体の高さ" },
                    { name: "XMV(10)", role: "操作変数 (冷却水流量)", desc: "反応熱を除去するためのジャケット冷却水コントロールバルブ" }
                ],
                twin: {
                    r2: "0.9948",
                    status: "completed",
                    formula: "c1 * xmeas_6_lag5 * xmeas_9 - c2 * xmeas_10 * xmeas_9 + c3 * xmeas_13 + c4",
                    insight: `
                        <strong>物理因果の分析結果（R² > 0.95 達成）:</strong>
                        <ul>
                            <li><strong>c1 * xmeas_6_lag5 * xmeas_9 (気相反応速度と質量保存):</strong> 上流の原料総流量 (xmeas_6) が配管を通り反応するまでの時間遅れを5分間のラグ (lag5) として精密に表現。これと反応器温度 (xmeas_9) の積により、高温かつフィード量が多いほど反応速度が指数関数的に増大し、生成ガス分子数が増加する気相ダイナミクスを忠実にモデル化。</li>
                            <li><strong>- c2 * xmeas_10 * xmeas_9 (非線形冷却収縮):</strong> 発熱反応熱を除去する冷却水流量 (xmeas_10) と反応温度 (xmeas_9) の積。温度が高いときほど冷却コイルの熱伝達（熱除去）が非線形に効率化し、結果として体積収縮による圧力降下を誘発する伝熱・熱力学物理特性と完全に整合。</li>
                            <li><strong>c3 * xmeas_13 (流体力学的背圧):</strong> 下流の気液分離器圧力 (xmeas_13) との結合。分離器圧力が上昇すると、配管で直結された反応器に対して背圧 (Back Pressure) として作用し、圧力伝播ループを構成する物理構造を忠実に再現。</li>
                            <li><strong>自己回帰項 (target_lag1) の完全排除:</strong> 自身の1ステップ前の過去値に頼る見かけの数値追従を一切行わず、周囲の境界物理因果だけでR² = 0.9948を自律的に達成。</li>
                        </ul>
                    `
                }
            },
            condenser: {
                title: "Condenser (凝縮器)",
                subtitle: "生成ガスの冷却・液化用熱交換器",
                status: "normal",
                description: "反応器から流出する高温ガスを急冷し、主生成物（液相）と未反応原料ガス（気相）に分離するための二相混合体へ変化させます。操作変数である冷却水流量により、下流の分離器に流入する気液比率が決定されます。",
                variables: [
                    { name: "XMV(11)", role: "操作変数 (CW流量)", desc: "凝縮器冷却水制御バルブ。これによって冷却効率が決定される。" }
                ],
                twin: null
            },
            separator: {
                title: "Vapor-Liquid Separator (気液分離器)",
                subtitle: "高圧フラッシュ気液分離ドラム",
                status: "completed",
                description: "冷却された流体から、未反応原料ガス（軽質分）を上部より分離し（コンプレッサー循環へ）、液化した反応生成物（重質分）を下部より抜出します。反応圧力に連動して分離器圧力が構成され、液位は物質収支（流出入差）の動的な積分値となる物理構造を有します。",
                variables: [
                    { name: "XMEAS(13)", role: "測定変数 (分離器圧力)", desc: "分離器内の気相部圧力。デジタルツイン構築完了。" },
                    { name: "XMEAS(12)", role: "測定変数 (分離器液位)", desc: "分離器下部の蓄積液レベル。積分特性（微分方程式）のため、探索方針を変更中。" },
                    { name: "XMEAS(11)", role: "測定変数 (分離器温度)", desc: "分離器の温度（気液平衡状態に直結）" },
                    { name: "XMV(7)", role: "操作変数 (アンダーフロー)", desc: "Stripperへ送出する液底抜出バルブ" }
                ],
                twin: {
                    r2: "0.9736",
                    status: "completed",
                    formula: "c1 * xmeas_7_lag5 - c2 * xmeas_10 + c3 * xmeas_11 + c4",
                    insight: `
                        <strong>物理因果の分析結果（R² > 0.95 達成）:</strong>
                        <ul>
                            <li><strong>c1 * xmeas_7_lag5 (気体力学的圧力伝播):</strong> 反応器圧力 (xmeas_7) のガス流体が、凝縮器や配管を通過して分離器に到達するまでの時間遅れを5分間のラグ (lag5) として完璧に記述。配管摩擦と差圧流動のダイナミクスを忠実に再現。</li>
                            <li><strong>- c2 * xmeas_10 (上流冷却の影響):</strong> 上流反応器での冷却水流量 (xmeas_10) の増大に伴う原料ガスの熱量喪失、運動エネルギー減衰、および局所的な熱収縮。これがマイナス符号の負の影響として分離器圧力を減圧させる因果関係を正しくモデル化。</li>
                            <li><strong>c3 * xmeas_11 (気液平衡と飽和蒸気圧):</strong> 分離器内の留出温度 (xmeas_11) 上昇による生成物の気化（フラッシュ）の進行、および気相部の飽和ガス分圧（飽和蒸気圧）の上昇。気液平衡 (VLE) と理想気体の状態方程式を物理的に完璧にトレースしています。</li>
                            <li><strong>自己回帰項 (target_lag1) の排除:</strong> 反応器と同様、自己相関への依存を完全に排除し、上流および隣接する熱力学パラメータだけからR² = 0.9736を突破。</li>
                            <li><strong>💡 何故、伝播遅延は2,3分ではなく「5分（lag5）」なのか？ (プロセス熱力学的裏付け):</strong> 
                                反応器圧力の変動が、凝縮器での冷却を伴う急激な相変化（気体から液体への凝縮）の際の巨大な熱容量遅延、および気液が混合した「気液二相流 (Two-Phase Flow)」化による圧力伝播速度（音速）の急激な低下（単相流時の1/10〜1/100に低下）、長大な配管内を流体が物理的に移動する物質滞留時間（ホールドアップ）が複合的に寄与するため、物理プロセスが再平衡に達してセンサー間の相関が最大化する時定数がちょうど 5 分（5ステップ）となります。
                            </li>
                        </ul>
                    `
                }
            },
            compressor: {
                title: "Compressor (コンプレッサー)",
                subtitle: "気体再循環・高圧循環用遠心圧縮機",
                status: "normal",
                description: "Separator上部から回収された未反応の軽質ガス（A, D, Eなど）を加圧し、反応器フィードへと高エネルギー回収循環させるための圧縮機です。リサイクル量を調整するバルブ開度(XMV 5)が、系全体の圧力循環ループとホールドアップに影響します。",
                variables: [
                    { name: "XMEAS(20)", role: "測定変数 (コンプレッサー仕事率)", desc: "圧縮機の電力消費量・仕事量" },
                    { name: "XMV(5)", role: "操作変数 (リサイクル弁)", desc: "リサイクルガス還流のバイパス開度制御バルブ" }
                ],
                twin: null
            },
            stripper: {
                title: "Stripper (ストリッパー蒸留塔)",
                subtitle: "生成物・不純物分離のための多段精製・放散塔",
                status: "normal",
                description: "Separatorから供給された不純物交じりの反応生成液体（Stream 10）に、下部から加熱水蒸気（Steam）を吹き込み、沸点の低い未反応成分を追い出して塔頂（Stream 5）から回収。高純度な最終製品液体を塔底（Stream 11）から連続的に抜き出します。",
                variables: [
                    { name: "XMEAS(15)", role: "測定変数 (塔底液位)", desc: "ストリッパー底部の液面レベル" },
                    { name: "XMEAS(16)", role: "測定変数 (ストリッパー圧力)", desc: "ストリッパー内の動作圧力" },
                    { name: "XMEAS(18)", role: "測定変数 (ストリッパー温度)", desc: "ストリッパー塔底付近のプロセス温度" },
                    { name: "XMV(9)", role: "操作変数 (スチーム弁)", desc: "加熱を制御するボトム水蒸気流量制御バルブ" }
                ],
                twin: null
            },

            // ----- STREAMS / PIPELINES -----
            s1: {
                title: "Stream 1: 原料 A 供給路",
                subtitle: "プラントへの原料A high 純度フィード",
                status: "normal",
                description: "気相原料Aを供給するパイプライン。反応器の主圧力や組成比に直接寄与。XMEAS(1)にて流量が連続監視され、XMV(3)バルブによりプロセス量（圧力目標値）に基づきフィードが絞られます。",
                variables: [
                    { name: "XMEAS(1)", role: "測定変数", desc: "ストリーム1 瞬時流量" },
                    { name: "XMV(3)", role: "操作変数", desc: "原料A 供給量制御バルブ" }
                ],
                twin: null
            },
            s2: {
                title: "Stream 2: 原料 D 供給路",
                subtitle: "プラントへの主要反応原料Dフィード",
                status: "normal",
                description: "気相・液相双方に寄与する高純度原料Dの供給流。製品の生成速度を決定づける最重要原料の1つです。流量はXMEAS(2)にマッピングされ、XMV(1)バルブにより制御されます。",
                variables: [
                    { name: "XMEAS(2)", role: "測定変数", desc: "ストリーム2 瞬時流量" },
                    { name: "XMV(1)", role: "操作変数", desc: "原料D 供給量制御バルブ" }
                ],
                twin: null
            },
            s3: {
                title: "Stream 3: 原料 E 供給路",
                subtitle: "反応器へ供給する副原料Eフィード",
                status: "normal",
                description: "副生物を制御しつつ目的生成物を得るための調整原料。流体バランスを微調整するため、XMEAS(3)およびXMV(2)によって流量をPID管理します。",
                variables: [
                    { name: "XMEAS(3)", role: "測定変数", desc: "ストリーム3 瞬時流量" },
                    { name: "XMV(2)", role: "操作変数", desc: "原料E 供給量制御バルブ" }
                ],
                twin: null
            },
            s4: {
                title: "Stream 4: 原料 A/C/B 混合供給路",
                subtitle: "不純物を含むリサイクル混合原料フィード",
                status: "normal",
                description: "原料A, C, Bを特定の初期比率で含む複合マテリアルフィード。プラント定常起動時の組成ホールドアップおよび、副反応蓄積の最大要因となるC成分の主流入ルート。XMEAS(4)およびXMV(4)により供給制御します。",
                variables: [
                    { name: "XMEAS(4)", role: "測定変数", desc: "ストリーム4 瞬時流量" },
                    { name: "XMV(4)", role: "操作変数", desc: "原料混合流 供給量制御バルブ" }
                ],
                twin: null
            },
            s6: {
                title: "Stream 6: 総反応フィード",
                subtitle: "反応器に入る全予熱混合フィード",
                status: "normal",
                description: "原料フィード1〜4、さらにコンプレッサーからのリサイクルガスとストリッパー塔頂回収ガスがすべて合流した、全フィード気流（XMEAS 6）。反応器への物質流入量に直接かつ瞬時に連動します。",
                variables: [
                    { name: "XMEAS(6)", role: "測定変数 (総流量)", desc: "反応器への総気相流入流量。反応器圧力の数式モデルにおける最重要ラグ因子。" }
                ],
                twin: null
            },
            s7: {
                title: "Stream 7: 反応器生成ガス路",
                subtitle: "反応器から Condenser へのエフラント",
                status: "normal",
                description: "生成物ガス、副生成物、および多量の未反応気体（原料A、Cなど）が高温・高圧で凝縮器に送られるメインストリーム。反応器圧力（XMEAS 7）と冷却凝縮効果との間で物理的圧力バランス（差圧伝播）が発生します。",
                variables: [
                    { name: "XMEAS(7)", role: "主圧力源", desc: "このストリームの起点となる反応器の圧力" }
                ],
                twin: null
            },
            s8: {
                title: "Stream 8: リサイクルガスライン",
                subtitle: " separator 塔頂からの回収ガスライン",
                status: "normal",
                description: "未反応の気体（高濃度A、CおよびリサイクルDガス）がコンプレッサーにフィードバックされる、高流量リサイクルループの上流。気液分離ドラム上部の圧力（XMEAS 13）の動的変化はこのガスの引抜レートに強く支配されます。",
                variables: [
                    { name: "XMEAS(13)", role: "主圧力源", desc: "このガスの起点となる気液分離器圧力" }
                ],
                twin: null
            },
            s10: {
                title: "Stream 10: 液相移送ライン",
                subtitle: "Separator ボトムから Stripper への液供給",
                status: "normal",
                description: "分離器下部で濃縮・液化した生成物を含む液体が、精製のためにストリッパーに送入されるパイプ。XMV(7)（アンダーフローバルブ）の開閉動作により、分離器液位（XMEAS 12）の積分値変動が発生します。",
                variables: [
                    { name: "XMEAS(12)", role: "起点液位", desc: "この液を引き抜く気液分離器の液位レベル" },
                    { name: "XMV(7)", role: "操作変数", desc: "液抜出量制御用アンダーフローバルブ" }
                ],
                twin: null
            },
            s5: {
                title: "Stream 5: ストリッパー回収ガス",
                subtitle: "塔頂から Mixer への回収軽質分リサイクル",
                status: "normal",
                description: "ストリッパー塔頂から留出する未反応原料（軽質ガス）を混合器に戻し、プラント効率を100%近くまで高めるループ。バルブ流量変化に伴い、反応フィード量に時間遅れを伴う外乱として寄与します。",
                variables: [],
                twin: null
            },
            s11: {
                title: "Stream 11: 最終製品抜出路",
                subtitle: "精製済高純度最終製品（Product G/H）",
                status: "normal",
                description: "不純物が除去された高品質の液体目的生成物が、システム外部の貯蔵タンクに回収されるストリーム。XMEAS(17)で抜出流量を測定し、XMV(8)バルブにてストリッパーの塔底液位が一定に保たれるよう自動制御されます。",
                variables: [
                    { name: "XMEAS(17)", role: "測定変数 (製品流量)", desc: "製品の生産速度に相当する瞬時流量" },
                    { name: "XMV(8)", role: "操作変数", desc: "最終製品の出荷制御バルブ" }
                ],
                twin: null
            },
            purge: {
                title: "Purge (不純物パージ路)",
                subtitle: "系内の不活性ガス（窒素等）蓄積を抑える連続抜出排気",
                status: "normal",
                description: "不純物（特に反応に関与しない不活性成分B）がループ内に蓄積すると、プラント圧力が上昇し効率が極端に低下します。これを防ぐため、一定割合 of 気体を系外（フレアスタック等）に廃棄する排気パイプです。XMEAS(10)で流量を監視し、XMV(6)パージバルブで圧力を制御します。",
                variables: [
                    { name: "XMEAS(10)", role: "測定変数 (パージ流量)", desc: "パージされた排気ガスの総流量" },
                    { name: "XMV(6)", role: "操作変数", desc: "系内のガスバランス（特に圧力制御）を維持するパージ弁" }
                ],
                twin: null
            },
            steam: {
                title: "Steam (ストリッパー加熱水蒸気フィード)",
                subtitle: "精製を促進する高圧熱水蒸気インプット",
                status: "normal",
                description: "ストリッパー塔底に直接高圧の蒸気を供給して再沸騰させ、液中の軽質揮発不純物を蒸発させて塔頂に追いやる熱量入力ストリーム。流量はXMEAS(19)に現れ、XMV(9)バルブによって塔底の必要プロセス温度に基づき制御されます。",
                variables: [
                    { name: "XMEAS(19)", role: "測定変数 (スチーム流量)", desc: "注入される過熱スチームの瞬時流量" },
                    { name: "XMV(9)", role: "操作変数", desc: "蒸気流量（ストリッパー熱量バランス）制御バルブ" }
                ],
                twin: null
            },
            product: {
                title: "Product (最終回収システム)",
                subtitle: "液体生成物の回収・監視ステーション",
                status: "normal",
                description: "最終製品としてのプロセス合格スペック（純度G/H）を保障して、プラント外部に出荷する工程点です。生産能力指標に直結します。",
                variables: [
                    { name: "XMEAS(17)", role: "製品流量", desc: "製品送出瞬時流量" },
                    { name: "XMV(8)", role: "製品送出弁", desc: "製品出荷流量制御用バルブ" }
                ],
                twin: null
            }
        };

        // UI Interactive Logic
        let selectedNodeId = null;
        let isAnimationActive = true;

        function selectNode(nodeId) {
            // Remove previous selections in SVG
            const allNodes = document.querySelectorAll('.node-machine');
            allNodes.forEach(node => node.classList.remove('selected'));

            // Clear current selection highlight in HTML
            selectedNodeId = nodeId;
            const data = plantData[nodeId];
            if (!data) return;

            // Highlight in SVG if it's a machine
            const targetSvgNode = document.getElementById(`node-${nodeId}`);
            if (targetSvgNode) {
                targetSvgNode.classList.add('selected');
            }

            // Update HTML Sidebar details
            document.getElementById('nodeTitle').innerText = data.title;
            document.getElementById('nodeSubtitle').innerText = data.subtitle;
            document.getElementById('nodeDescription').innerHTML = data.description;

            // Update Badge based on status
            const badgeContainer = document.getElementById('nodeStatusBadge');
            badgeContainer.innerHTML = '';
            if (data.status === 'completed') {
                badgeContainer.innerHTML = '<span class="status-badge completed">デジタルツイン完了</span>';
            } else if (data.status === 'target') {
                badgeContainer.innerHTML = '<span class="status-badge target">開発中ターゲット</span>';
            } else {
                badgeContainer.innerHTML = '<span class="status-badge normal">監視対象プロセス</span>';
            }

            // Update Digital Twin Section
            const twinSection = document.getElementById('twinSection');
            if (data.twin) {
                twinSection.style.display = 'block';
                const card = document.getElementById('twinCard');
                card.className = `twin-card ${data.twin.status}`;
                
                document.getElementById('twinR2').innerText = `R²: ${data.twin.r2}`;
                document.getElementById('twinFormula').innerText = data.twin.formula;
                document.getElementById('twinInsight').innerHTML = data.twin.insight;

                if (data.twin.status === 'completed') {
                    document.getElementById('twinStatusLabel').innerText = "検証済 物理モデル方程式";
                } else {
                    document.getElementById('twinStatusLabel').innerText = "探索中・パラメータ調整中";
                }
            } else {
                twinSection.style.display = 'none';
            }

            // Update Associated Variables Section
            const variablesSection = document.getElementById('variablesSection');
            const variablesList = document.getElementById('variablesList');
            variablesList.innerHTML = '';

            if (data.variables && data.variables.length > 0) {
                variablesSection.style.display = 'block';
                data.variables.forEach(v => {
                    const item = document.createElement('div');
                    item.className = 'variable-item';
                    item.innerHTML = `
                        <div class="var-meta">
                            <span class="var-name">${v.name}</span>
                            <span class="var-role">${v.role}</span>
                        </div>
                        <div class="var-desc">${v.desc}</div>
                    `;
                    variablesList.appendChild(item);
                });
            } else {
                variablesSection.style.display = 'none';
            }
        }

        // CONTROL BAR LOGIC
        // Toggle Pipe Flow Animations
        const btnToggleAnimation = document.getElementById('btnToggleAnimation');
        btnToggleAnimation.addEventListener('click', () => {
            const flows = document.querySelectorAll('.pipe-flow');
            isAnimationActive = !isAnimationActive;
            
            if (isAnimationActive) {
                flows.forEach(flow => {
                    flow.style.animationPlayState = 'running';
                });
                btnToggleAnimation.innerHTML = `
                    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="display:inline; vertical-align:middle; margin-right:4px;">
                        <rect x="6" y="4" width="4" height="16" fill="currentColor"></rect>
                        <rect x="14" y="4" width="4" height="16" fill="currentColor"></rect>
                    </svg>
                    アニメーション停止
                `;
                btnToggleAnimation.classList.remove('paused');
            } else {
                flows.forEach(flow => {
                    flow.style.animationPlayState = 'paused';
                });
                btnToggleAnimation.innerHTML = `
                    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" style="display:inline; vertical-align:middle; margin-right:4px;">
                        <polygon points="5 3 19 12 5 21 5 3" fill="currentColor"></polygon>
                    </svg>
                    アニメーション再生
                `;
                btnToggleAnimation.classList.add('paused');
            }
        });

        // Highlight Completed Twins
        document.getElementById('btnHighlightCompleted').addEventListener('click', () => {
            resetMachineHighlights();
            const comp = document.querySelectorAll('.node-machine.twin-completed');
            comp.forEach(el => {
                const innerRects = el.querySelectorAll('rect, ellipse, path');
                innerRects.forEach(rect => {
                    rect.style.stroke = '#16a34a';
                    rect.style.strokeWidth = '2px';
                });
            });
        });

        // Highlight Targets Under Development
        document.getElementById('btnHighlightTargets').addEventListener('click', () => {
            resetMachineHighlights();
            const targets = ['reactor', 'separator'];
            targets.forEach(id => {
                const el = document.getElementById(`node-${id}`);
                if (el) {
                    const innerRects = el.querySelectorAll('rect, ellipse, path');
                    innerRects.forEach(rect => {
                        rect.style.stroke = '#b45309';
                        rect.style.strokeWidth = '2px';
                    });
                }
            });
        });

        // Reset display filters
        const btnResetFilters = document.getElementById('btnResetFilters');
        btnResetFilters.addEventListener('click', () => {
            resetMachineHighlights();
        });

        function resetMachineHighlights() {
            const allMachines = document.querySelectorAll('.node-machine');
            allMachines.forEach(el => {
                const innerRects = el.querySelectorAll('rect, ellipse, path');
                innerRects.forEach(rect => {
                    rect.style.stroke = '';
                    rect.style.strokeWidth = '';
                });
            });
        }

        // Initialize with Reactor Selected
        window.onload = () => {
            selectNode('reactor');
        };
    