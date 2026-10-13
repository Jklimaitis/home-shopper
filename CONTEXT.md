# Domínio do home_shopper

O home_shopper organiza itens encontrados em compras para comparar preços entre lojas, distinguindo a identidade do conteúdo de suas formas de venda. Este glossário registra os conceitos alinhados durante a discussão; não descreve a implementação.

## Linguagem

**Produto canônico**: identidade do conteúdo comprado e das características relevantes à sua equivalência, segundo a categoria. Diferenças de tamanho ou recipiente, isoladamente, não definem outro produto.
_Evitar_: usar descrição do cupom, código interno da loja ou categoria como se fossem a identidade do produto.

**Variante**: conjunto de características do conteúdo que distingue um produto de outro dentro de uma categoria, como teor de gordura e condição de lactose no leite. Essas características podem ser independentes e precisam ser consideradas em conjunto. No escopo do home_shopper, refrigeração ou congelamento, isoladamente, não distingue variantes de uma carne equivalente.
_Evitar_: tratar todo modificador do nome ou todo tamanho como uma variante de conteúdo.

**Apresentação**: forma comercial em que um produto é vendido, incluindo quantidade de conteúdo, unidade, tipo de embalagem e configuração do pacote. Apresentações diferentes podem pertencer ao mesmo produto canônico quando a equivalência do conteúdo estiver confirmada.
_Evitar_: usar produto e apresentação como termos intercambiáveis.

**Unidade de venda**: unidade em que o emissor expressa a quantidade vendida e seu preço unitário, como unidade ou quilograma. A interpretação deve ser coerente com a apresentação comercial identificada.
_Evitar_: deduzir a unidade de cobrança apenas da quantidade mencionada no nome do produto.

**Preço unitário de venda**: valor cobrado por uma unidade de venda, antes de multiplicar pela quantidade comprada. Não se confunde com o total da linha nem com um preço agregado para comparação entre lojas.
_Evitar_: interpretar todo preço de uma embalagem como preço por quilograma.

**Descrição do cupom**: texto usado pelo emissor para identificar um item registrado na compra. Pode ser abreviado ou variar entre lojas sem indicar, por si só, mudança no produto ou na apresentação.
_Evitar_: tratar semelhança textual como confirmação de equivalência.

**Código interno da loja**: identificador atribuído pelo emissor ao item vendido, com significado no contexto daquela loja. Pode estar ausente e não identifica globalmente o produto.
_Evitar_: tratá-lo como EAN ou como identidade compartilhada entre lojas.

**Candidato de vínculo (código impresso validado por GS1)**: código impresso pela loja que passa no crivo GS1 (comprimento 8/12/13/14 mais dígito verificador mod-10) e, por isso, pode sugerir um vínculo revisável — nunca um descarte nem uma confirmação de identidade. O candidato permanece pendente de revisão humana até que a associação seja confirmada ou descartada.
_Evitar_: tratar validação GS1 como certeza de equivalência ou como rejeição automática do código.

**EAN**: identificador do item comercial associado ao código de barras de sua embalagem. Apresentações de um mesmo produto canônico podem ter identificadores diferentes; sua ausência não impede uma equivalência confirmada por outras informações.
_Evitar_: tratá-lo como código interno de loja ou como identificador obrigatório do produto canônico.

**Equivalência confirmada**: conclusão sustentada por informações suficientes de que duas identificações correspondem ao mesmo produto canônico. Dúvida, contradição ou informação insuficiente mantém a associação pendente de revisão.
_Evitar_: confundir igualdade de unidade de medida ou de palavras com equivalência de conteúdo.
