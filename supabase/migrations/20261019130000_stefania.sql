-- Nome de exibição: Estefânia passa a ser Stefânia (C4: só o texto muda; códigos
-- e efeitos das cartas continuam iguais).

update app_private.card_definitions
set character_name = 'Stefânia'
where character_name = 'Estefânia';
