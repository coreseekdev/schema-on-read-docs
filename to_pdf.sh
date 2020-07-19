bundle exec asciidoctor -r asciidoctor-diagram  -r asciidoctor-pdf -b pdf  -a scripts=cjk \
    -a pdf-theme=../cjk-data/themes/KaiGenGothicCN-theme.yml -a pdf-fontsdir=../cjk-data/fonts index.adoc
